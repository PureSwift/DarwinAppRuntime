import DynamicUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colors, alignments and fonts from IR props (`SwiftUIRenderer.md` §5).
enum Styles {

    // MARK: Colors

    /// A platform color name, `[name, opacity]`, or a fixed `0xAARRGGBB`
    /// int. `nil` for anything else.
    static func color(_ value: PropValue?) -> Color? {
        switch value {
        case .string(let name):
            return namedColor(name)
        case .array(let values):
            guard values.count == 2, let name = values[0].string, let opacity = values[1].double,
                  let color = namedColor(name) else { return nil }
            return color.opacity(opacity)
        case .int(let value):
            let argb = UInt32(truncatingIfNeeded: value)
            func channel(_ shift: UInt32) -> Double {
                Double((argb >> shift) & 0xFF) / 255
            }
            return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: channel(24))
        default:
            return nil
        }
    }

    /// A named color as the platform's semantic color, so it follows light
    /// and dark appearance and accessibility settings.
    static func namedColor(_ name: String) -> Color? {
        switch name {
        case "primary": return .primary
        case "secondary": return .secondary
        case "accentColor": return .accentColor
        case "clear": return .clear
        case "black": return .black
        case "white": return .white
        #if canImport(UIKit)
        case "gray": return Color(UIColor.systemGray)
        case "red": return Color(UIColor.systemRed)
        case "orange": return Color(UIColor.systemOrange)
        case "yellow": return Color(UIColor.systemYellow)
        case "green": return Color(UIColor.systemGreen)
        case "mint": return Color(UIColor.systemMint)
        case "teal": return Color(UIColor.systemTeal)
        case "cyan": return Color(UIColor.systemCyan)
        case "blue": return Color(UIColor.systemBlue)
        case "indigo": return Color(UIColor.systemIndigo)
        case "purple": return Color(UIColor.systemPurple)
        case "pink": return Color(UIColor.systemPink)
        case "brown": return Color(UIColor.systemBrown)
        #elseif canImport(AppKit)
        case "gray": return Color(NSColor.systemGray)
        case "red": return Color(NSColor.systemRed)
        case "orange": return Color(NSColor.systemOrange)
        case "yellow": return Color(NSColor.systemYellow)
        case "green": return Color(NSColor.systemGreen)
        case "mint": return Color(NSColor.systemMint)
        case "teal": return Color(NSColor.systemTeal)
        case "cyan": return Color(NSColor.systemCyan)
        case "blue": return Color(NSColor.systemBlue)
        case "indigo": return Color(NSColor.systemIndigo)
        case "purple": return Color(NSColor.systemPurple)
        case "pink": return Color(NSColor.systemPink)
        case "brown": return Color(NSColor.systemBrown)
        #endif
        default: return nil
        }
    }

    // MARK: Alignment

    static func horizontal(_ value: PropValue?) -> HorizontalAlignment {
        switch value?.string {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    static func vertical(_ value: PropValue?) -> VerticalAlignment {
        switch value?.string {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    /// From `horizontal` and `vertical` props.
    static func alignment(_ props: [String: PropValue]) -> Alignment {
        Alignment(horizontal: horizontal(props["horizontal"]), vertical: vertical(props["vertical"]))
    }

    static func textAlignment(_ value: PropValue?) -> TextAlignment {
        switch value?.string {
        case "center": return .center
        case "trailing": return .trailing
        default: return .leading
        }
    }

    // MARK: Numbers

    /// A finite, non-negative length, or `nil`.
    static func length(_ value: PropValue?) -> CGFloat? {
        guard let double = value?.double, double.isFinite, double >= 0 else { return nil }
        return CGFloat(double)
    }

    /// A non-negative length, where `∞` fills the space offered.
    static func flexibleLength(_ value: PropValue?) -> CGFloat? {
        guard let double = value?.double, !double.isNaN, double >= 0 else { return nil }
        return double.isInfinite ? .infinity : CGFloat(double)
    }

    /// A finite number, or `fallback`.
    static func number(_ value: PropValue?, _ fallback: CGFloat = 0) -> CGFloat {
        guard let double = value?.double, double.isFinite else { return fallback }
        return CGFloat(double)
    }

    // MARK: Fonts

    static func textStyle(_ name: String?) -> Font.TextStyle? {
        switch name {
        case "largeTitle": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "body": return .body
        case "callout": return .callout
        case "footnote": return .footnote
        case "caption": return .caption
        case "caption2": return .caption2
        default: return nil
        }
    }

    static func weight(_ name: String?) -> Font.Weight? {
        switch name {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return nil
        }
    }

    static func design(_ name: String?) -> Font.Design? {
        switch name {
        case "default": return .default
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        default: return nil
        }
    }

    // MARK: Controls

    static func buttonRole(_ value: PropValue?) -> ButtonRole? {
        switch value?.string {
        case "destructive": return .destructive
        case "cancel": return .cancel
        default: return nil
        }
    }

    // MARK: Grids

    /// A grid's columns or rows. One flexible item when there are none.
    static func gridItems(_ value: PropValue?) -> [GridItem] {
        guard case .array(let values) = value else { return [GridItem(.flexible())] }
        let items = values.compactMap(gridItem)
        return items.isEmpty ? [GridItem(.flexible())] : items
    }

    /// `[size, a, b, spacing, horizontal, vertical]` (`RenderIR.md`), or
    /// `nil` if it isn't one. Lengths are made safe for SwiftUI: an adaptive
    /// item is at least a point wide, and a maximum is at least its minimum.
    static func gridItem(_ value: PropValue) -> GridItem? {
        guard case .array(let parts) = value, parts.count >= 3, let kind = parts[0].string else { return nil }
        let first = length(parts[1]) ?? 0
        let maximum = flexibleLength(parts[2]) ?? .infinity
        let spacing = parts.count > 3 ? length(parts[3]) : nil
        let alignment = parts.count > 5 ? Self.alignment(["horizontal": parts[4], "vertical": parts[5]]) : nil
        let size: GridItem.Size
        switch kind {
        case "fixed":
            size = .fixed(first)
        case "flexible":
            size = .flexible(minimum: first, maximum: max(first, maximum))
        case "adaptive":
            let minimum = max(1, first)
            size = .adaptive(minimum: minimum, maximum: max(minimum, maximum))
        default:
            return nil
        }
        return GridItem(size, spacing: spacing, alignment: alignment)
    }
}

/// The font the IR's inherited `font`, `fontWeight` and `italic` modifiers
/// add up to at a node. Kept in the environment, so a descendant's
/// `fontWeight` adjusts its ancestor's `font`.
struct FontSpec: Equatable {

    var style: String?

    var size: Double?

    var design: String?

    var weight: String?

    var italic: Bool?

    /// The spec after one of the font modifiers.
    func adjusted(by modifier: ModifierNode) -> FontSpec {
        var spec = self
        let args = modifier.args
        switch modifier.kind {
        case "font":
            spec.style = args["style"]?.string
            spec.size = args["size"]?.double
            spec.design = args["design"]?.string
            if let weight = args["weight"] {
                spec.weight = weight.string
            }
            if let italic = args["italic"] {
                spec.italic = italic.bool
            }
        case "fontWeight":
            spec.weight = args["weight"]?.string
        case "italic":
            spec.italic = args["value"]?.bool
        default:
            break
        }
        return spec
    }

    /// `nil` when nothing is set: the platform's default font for the
    /// context.
    var font: Font? {
        let weight = Styles.weight(weight)
        let design = Styles.design(design)
        var font: Font
        if let size, size.isFinite, size > 0 {
            font = .system(size: CGFloat(size), weight: weight ?? .regular, design: design ?? .default)
        } else if let style = Styles.textStyle(style) {
            font = design.map { .system(style, design: $0) } ?? Font.system(style)
            if let weight {
                font = font.weight(weight)
            }
        } else if weight != nil || italic == true {
            font = .body
            if let weight {
                font = font.weight(weight)
            }
        } else {
            return nil
        }
        if italic == true {
            font = font.italic()
        }
        return font
    }
}

private struct FontSpecKey: EnvironmentKey {
    static let defaultValue = FontSpec()
}

/// Whether a view is in a `List`, where `NavigationLink` nodes show a
/// chevron.
private struct InListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {

    var renderFont: FontSpec {
        get { self[FontSpecKey.self] }
        set { self[FontSpecKey.self] = newValue }
    }

    var renderInList: Bool {
        get { self[InListKey.self] }
        set { self[InListKey.self] = newValue }
    }
}

/// Applies a `font`, `fontWeight` or `italic` modifier over the inherited
/// font.
struct FontModifier: ViewModifier {

    let modifier: ModifierNode

    @Environment(\.renderFont) private var inherited

    func body(content: Content) -> some View {
        let spec = inherited.adjusted(by: modifier)
        content
            .font(spec.font)
            .environment(\.renderFont, spec)
    }
}
