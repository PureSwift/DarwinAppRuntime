import DynamicUI
import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
#endif

// MARK: The keyboard's modifiers

private struct AutocorrectionDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AutocapitalizationKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {

    /// The IR's `autocorrection` modifier, inherited.
    public internal(set) var renderAutocorrectionDisabled: Bool {
        get { self[AutocorrectionDisabledKey.self] }
        set { self[AutocorrectionDisabledKey.self] = newValue }
    }

    /// The IR's `autocapitalization` modifier, inherited: `never`, `words`,
    /// `sentences` or `characters`; `nil` for the platform's way.
    public internal(set) var renderAutocapitalization: String? {
        get { self[AutocapitalizationKey.self] }
        set { self[AutocapitalizationKey.self] = newValue }
    }
}

/// `autocorrection` and `autocapitalization` (`Contracts/TextEditor.md`):
/// SwiftUI's own for a `TextField` and a `Searchable`, and in the
/// environment for a text view that isn't SwiftUI's.
struct KeyboardModifier: ViewModifier {

    let modifier: ModifierNode

    func body(content: Content) -> some View {
        switch modifier.kind {
        case "autocorrection":
            let disabled = modifier.args["disabled"]?.bool ?? true
            content
                .disableAutocorrection(disabled)
                .environment(\.renderAutocorrectionDisabled, disabled)
        default:
            let mode = modifier.args["mode"]?.string
            #if os(iOS)
            content
                .textInputAutocapitalization(Self.capitalization(mode))
                .environment(\.renderAutocapitalization, mode)
            #else
            // No on-screen keyboard.
            content
                .environment(\.renderAutocapitalization, mode)
            #endif
        }
    }

    #if os(iOS)
    static func capitalization(_ mode: String?) -> TextInputAutocapitalization? {
        switch mode {
        case "never": .never
        case "words": .words
        case "sentences": .sentences
        case "characters": .characters
        default: nil
        }
    }
    #endif
}

// MARK: Focus

/// A `focused` modifier on a view SwiftUI focuses, such as a `TextField`
/// (`RenderIR.md`): it gives or takes the keyboard when `value` differs
/// from what was last rendered or reported, and reports `focus` when the
/// user moves it.
struct FocusModifier: ViewModifier {

    let value: Bool

    let report: (Bool) -> Void

    @FocusState private var focused: Bool

    /// What was last rendered or reported.
    @State private var last: Bool?

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear {
                last = value
                if value {
                    focused = true
                }
            }
            .onChange(of: value) { value in
                guard value != last else { return }
                last = value
                focused = value
            }
            .onChange(of: focused) { focused in
                guard focused != last else { return }
                last = focused
                report(focused)
            }
    }
}

/// A `focused` modifier on a view the renderer doesn't draw itself, such
/// as a `TextEditor`: the view gives or takes the keyboard, by the same
/// rule as `FocusModifier`, and reports.
public struct FocusLink {

    /// Whether the guest wants the view to have the keyboard.
    public let value: Bool

    /// Says the user moved the keyboard into or out of the view.
    public let report: (Bool) -> Void
}

// MARK: Text editors

/// What a `TextEditor` node asks for (`Contracts/TextEditor.md`).
public struct TextEditorNode {

    /// A `TextStorage`'s `identifier()`.
    public let buffer: Int32

    public let isEditable: Bool

    public let wrapsLines: Bool

    /// The node's `focused` modifier, if it has one.
    public let focus: FocusLink?
}

/// What `TextEditor` nodes show: the text view of the text whose
/// `identifier()` they carry. `DarwinText` provides them when the app uses
/// `TextStorage`; without it, a `TextEditor` shows nothing.
public enum TextEditorViews {

    /// Makes the view of a text.
    public static var provider: ((TextEditorNode) -> AnyView)?

    static func view(_ node: RenderNode, report: @escaping (Bool) -> Void) -> AnyView {
        guard let provider, let value = node.props["buffer"]?.int, let buffer = Int32(exactly: value) else {
            return AnyView(EmptyView())
        }
        let focused = node.modifiers.last { $0.kind == "focused" }
        return provider(TextEditorNode(
            buffer: buffer,
            isEditable: node.props["editable"]?.bool ?? true,
            wrapsLines: node.props["wraps"]?.bool ?? true,
            focus: focused.map { FocusLink(value: $0.args["value"]?.bool ?? false, report: report) }
        ))
    }
}

// MARK: Fonts

extension FontSpec {

    /// The platform's font for the spec; `nil` when nothing is set, for the
    /// body font.
    public var platformFont: PlatformFont? {
        let weight = Self.weight(weight)
        var font: PlatformFont
        if let size, size.isFinite, size > 0 {
            font = .systemFont(ofSize: CGFloat(size), weight: weight ?? .regular)
        } else if let style = Self.textStyle(style) {
            font = .preferredFont(forTextStyle: style)
            if let weight {
                font = .systemFont(ofSize: font.pointSize, weight: weight)
            }
        } else if weight != nil || italic == true {
            font = .preferredFont(forTextStyle: .body)
            if let weight {
                font = .systemFont(ofSize: font.pointSize, weight: weight)
            }
        } else {
            return nil
        }
        return Self.styled(font, design: design, italic: italic == true)
    }

    private static func styled(_ font: PlatformFont, design: String?, italic: Bool) -> PlatformFont {
        #if canImport(UIKit)
        var descriptor = font.fontDescriptor
        if let design = Self.design(design), let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = slanted
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var descriptor = font.fontDescriptor
        if let design = Self.design(design), let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    private static func weight(_ name: String?) -> PlatformFont.Weight? {
        switch name {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: nil
        }
    }

    private static func textStyle(_ name: String?) -> PlatformFont.TextStyle? {
        switch name {
        case "largeTitle": .largeTitle
        case "title": .title1
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "subheadline": .subheadline
        case "body": .body
        case "callout": .callout
        case "footnote": .footnote
        case "caption": .caption1
        case "caption2": .caption2
        default: nil
        }
    }

    private static func design(_ name: String?) -> PlatformFontDescriptor.SystemDesign? {
        switch name {
        case "default": .default
        case "serif": .serif
        case "rounded": .rounded
        case "monospaced": .monospaced
        default: nil
        }
    }
}

#if canImport(UIKit)
typealias PlatformFontDescriptor = UIFontDescriptor
#else
typealias PlatformFontDescriptor = NSFontDescriptor
#endif
