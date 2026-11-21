import DarwinUI
import RuntimeText
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What a `TextEditor` node shows: the text view of the text whose
/// `identifier()` it carries, or nothing once the guest released it.
///
/// The text view moves into this view's container while it's shown, and
/// out of it when the node goes. The text keeps its selection, scroll and
/// undo history either way. A second node showing the same text takes the
/// view, and the first is empty.
///
/// It applies the node's `editable` and `wraps`, the inherited font and
/// keyboard modifiers, and its `focused` modifier.
struct TextEditorView: View {

    let node: TextEditorNode

    var body: some View {
        if let engine = HostTextStorage.storage(for: node.buffer)?.engine as? TextViewEngine {
            PlatformTextView(engine: engine, node: node)
        }
    }
}

/// What was last rendered or reported of a text view's focus: the keyboard
/// moves only when the guest's value differs from it.
final class FocusMemory {
    var last: Bool?
}

private struct Settings {

    let font: PlatformFont

    let autocorrectionDisabled: Bool

    let autocapitalization: String?

    init(_ environment: EnvironmentValues) {
        font = environment.renderFont.platformFont ?? .preferredFont(forTextStyle: .body)
        autocorrectionDisabled = environment.renderAutocorrectionDisabled
        autocapitalization = environment.renderAutocapitalization
    }
}

#if canImport(UIKit)

private struct PlatformTextView: UIViewRepresentable {

    let engine: TextViewEngine

    let node: TextEditorNode

    func makeCoordinator() -> FocusMemory {
        FocusMemory()
    }

    func makeUIView(context: Context) -> TextHolder {
        let holder = TextHolder()
        holder.show(engine)
        return holder
    }

    func updateUIView(_ holder: TextHolder, context: Context) {
        holder.show(engine)
        let view = engine.view
        let settings = Settings(context.environment)
        view.isEditable = node.isEditable
        view.isSelectable = true
        if view.font != settings.font {
            view.font = settings.font
        }
        view.autocorrectionType = settings.autocorrectionDisabled ? .no : .default
        view.spellCheckingType = settings.autocorrectionDisabled ? .no : .default
        view.autocapitalizationType = Self.capitalization(settings.autocapitalization)
        let container = view.textContainer
        if node.wrapsLines != container.widthTracksTextView {
            container.widthTracksTextView = node.wrapsLines
            if !node.wrapsLines {
                // As wide as the longest line, in a view that scrolls sideways.
                container.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        sync(focus: context.coordinator)
    }

    private func sync(focus state: FocusMemory) {
        let view = engine.view
        guard let focus = node.focus else {
            engine.onFocus = nil
            return
        }
        engine.onFocus = { focused in
            guard focused != state.last else { return }
            state.last = focused
            focus.report(focused)
        }
        guard focus.value != state.last else { return }
        state.last = focus.value
        // After this update, once the view is in a window.
        DispatchQueue.main.async {
            if focus.value {
                _ = view.becomeFirstResponder()
            } else if view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ holder: TextHolder, coordinator: FocusMemory) {
        holder.show(nil)
    }

    static func capitalization(_ mode: String?) -> UITextAutocapitalizationType {
        switch mode {
        case "never": .none
        case "words": .words
        case "characters": .allCharacters
        default: .sentences
        }
    }
}

/// Holds a text's view while a node shows it.
final class TextHolder: UIView {

    private(set) weak var engine: TextViewEngine?

    func show(_ engine: TextViewEngine?) {
        if let old = self.engine, old !== engine, old.view.superview === self {
            old.view.removeFromSuperview()
        }
        self.engine = engine
        guard let view = engine?.view, view.superview !== self else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
}

#else

private struct PlatformTextView: NSViewRepresentable {

    let engine: TextViewEngine

    let node: TextEditorNode

    func makeCoordinator() -> FocusMemory {
        FocusMemory()
    }

    func makeNSView(context: Context) -> TextHolder {
        let holder = TextHolder()
        holder.show(engine)
        return holder
    }

    func updateNSView(_ holder: TextHolder, context: Context) {
        holder.show(engine)
        let view = engine.view
        let settings = Settings(context.environment)
        view.isEditable = node.isEditable
        view.isSelectable = true
        if view.font != settings.font {
            view.font = settings.font
        }
        view.isAutomaticSpellingCorrectionEnabled = !settings.autocorrectionDisabled
        view.isContinuousSpellCheckingEnabled = !settings.autocorrectionDisabled
        wrap(node.wrapsLines)
        sync(focus: context.coordinator)
    }

    private func wrap(_ wraps: Bool) {
        let view = engine.view
        guard let container = view.textContainer, container.widthTracksTextView != wraps else { return }
        let huge = CGFloat.greatestFiniteMagnitude
        engine.scrollView.hasHorizontalScroller = !wraps
        view.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            container.containerSize = NSSize(width: engine.scrollView.contentSize.width, height: huge)
            view.frame.size.width = engine.scrollView.contentSize.width
        } else {
            view.maxSize = NSSize(width: huge, height: huge)
            container.containerSize = NSSize(width: huge, height: huge)
        }
    }

    private func sync(focus state: FocusMemory) {
        let view = engine.view
        guard let focus = node.focus else {
            engine.onFocus = nil
            return
        }
        engine.onFocus = { focused in
            guard focused != state.last else { return }
            state.last = focused
            focus.report(focused)
        }
        guard focus.value != state.last else { return }
        state.last = focus.value
        DispatchQueue.main.async {
            if focus.value {
                view.window?.makeFirstResponder(view)
            } else if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
        }
    }

    static func dismantleNSView(_ holder: TextHolder, coordinator: FocusMemory) {
        holder.show(nil)
    }
}

/// Holds a text's scroll view while a node shows it.
final class TextHolder: NSView {

    private(set) weak var engine: TextViewEngine?

    func show(_ engine: TextViewEngine?) {
        if let old = self.engine, old !== engine, old.scrollView.superview === self {
            old.scrollView.removeFromSuperview()
        }
        self.engine = engine
        guard let scrollView = engine?.scrollView, scrollView.superview !== self else { return }
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }
}

#endif
