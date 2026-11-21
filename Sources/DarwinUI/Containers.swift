import DynamicUI
import SwiftUI

/// A `Grid` node (`SwiftUIRenderer.md` §3): SwiftUI's `Grid` on iOS 16 and
/// macOS 13; before them, a stack of rows, so cells line up only when
/// they're the same width.
struct GridView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let props = model.node.props
        let alignment = Styles.alignment(props)
        let horizontalSpacing = Styles.length(props["horizontalSpacing"])
        let verticalSpacing = Styles.length(props["verticalSpacing"])
        let rows = model.childIDs.compactMap { store.model($0) }
        if #available(iOS 16, macOS 13, *) {
            Grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
                ForEach(rows) { row in
                    GridRowView(row: row, store: store)
                }
            }
        } else {
            VStack(alignment: alignment.horizontal, spacing: verticalSpacing) {
                ForEach(rows) { row in
                    StackRowView(row: row, alignment: alignment.vertical, spacing: horizontalSpacing, store: store)
                }
            }
        }
    }
}

/// A child of a `Grid`: a `GridRow` of cells, or a view across the grid.
@available(iOS 16, macOS 13, *)
private struct GridRowView: View {

    @ObservedObject var row: NodeModel

    let store: RenderStore

    var body: some View {
        if row.node.type == "GridRow" {
            let alignment = row.node.props["alignment"].map { Styles.vertical($0) }
            GridRow(alignment: alignment) {
                ChildrenView(ids: row.childIDs, store: store)
            }
        } else {
            NodeView(model: row, store: store)
        }
    }
}

/// Before `Grid`: a `GridRow` as an `HStack`.
private struct StackRowView: View {

    @ObservedObject var row: NodeModel

    let alignment: VerticalAlignment

    let spacing: CGFloat?

    let store: RenderStore

    var body: some View {
        if row.node.type == "GridRow" {
            let alignment = row.node.props["alignment"].map { Styles.vertical($0) } ?? self.alignment
            HStack(alignment: alignment, spacing: spacing) {
                ChildrenView(ids: row.childIDs, store: store)
            }
        } else {
            NodeView(model: row, store: store)
        }
    }
}

/// A `DisclosureGroup` node: its first child is the label, the rest the
/// content, which the guest sends only while it's expanded.
struct DisclosureView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let model = self.model
        let store = self.store
        let expanded = Binding<Bool>(
            get: { model.value?.bool ?? false },
            set: { store.change(model, to: .bool($0)) }
        )
        DisclosureGroup(isExpanded: expanded) {
            ChildrenView(ids: Array(model.childIDs.dropFirst()), store: store)
        } label: {
            ChildView(id: model.childIDs.first, store: store)
        }
    }
}

/// A `Link` node: opens its `url`, or just shows its label if the URL
/// isn't one.
struct LinkNodeView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        if let string = model.node.props["url"]?.string, let url = URL(string: string), url.scheme != nil {
            Link(destination: url) {
                ChildrenView(ids: model.childIDs, store: store)
            }
        } else {
            ChildrenView(ids: model.childIDs, store: store)
        }
    }
}

/// A `SwipeActions` node: its first child, the row, with the other children
/// as swipe buttons.
struct SwipeActionsView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let props = model.node.props
        let edge: HorizontalEdge = props["edge"]?.string == "leading" ? .leading : .trailing
        let actions = model.childIDs.dropFirst().compactMap { store.model($0) }
        ChildView(id: model.childIDs.first, store: store)
            .swipeActions(edge: edge, allowsFullSwipe: props["allowsFullSwipe"]?.bool ?? true) {
                ForEach(actions) { action in
                    ActionButton(model: action, store: store)
                }
            }
    }
}

/// A `Searchable` node: its child with a search field in the navigation
/// bar, synced like a text field.
struct SearchableView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let model = self.model
        let store = self.store
        let text = Binding<String>(
            get: { model.value?.string ?? "" },
            set: { store.change(model, to: .string($0)) }
        )
        let prompt = model.node.props["prompt"]?.string.map { Text(verbatim: $0) }
        ChildView(id: model.childIDs.first, store: store)
            .searchable(text: text, prompt: prompt)
            .onSubmit(of: .search) { store.send(model.id, .submit) }
    }
}

/// What `GLSurface` nodes show (`RenderIR.md`): a surface's GL view, by
/// its `identifier()`. `DarwinGraphics` provides them when the app uses
/// `Surface`; without it, a `GLSurface` shows nothing.
public enum GLSurfaceViews {

    /// Makes the view of the surface with an identifier.
    public static var provider: ((Int32) -> AnyView)?

    static func view(_ surface: PropValue?) -> AnyView {
        guard let provider, let value = surface?.int, let identifier = Int32(exactly: value) else {
            return AnyView(EmptyView())
        }
        return provider(identifier)
    }
}

/// What `WebView` nodes show (`RenderIR.md`): a page's web view, by its
/// `identifier()`. `DarwinWebKit` provides them when the app uses
/// `WebContent`; without it, a `WebView` shows nothing.
public enum WebViews {

    /// Makes the view of the page with an identifier.
    public static var provider: ((Int32) -> AnyView)?

    static func view(_ page: PropValue?) -> AnyView {
        guard let provider, let value = page?.int, let identifier = Int32(exactly: value) else {
            return AnyView(EmptyView())
        }
        return provider(identifier)
    }
}

/// What `VideoPlayer` nodes show (`RenderIR.md`): a player's picture, by
/// its `identifier()`, with the node's `scaling` and `controls`.
/// `DarwinMedia` provides them when the app uses `MediaPlayback`; without
/// it, a `VideoPlayer` shows nothing.
public enum VideoPlayers {

    /// Makes the view of the player with an identifier, scaled and with
    /// the controls the node asks for.
    public static var provider: ((_ player: Int32, _ scaling: String?, _ controls: String?) -> AnyView)?

    static func view(_ props: [String: PropValue]) -> AnyView {
        guard let provider, let value = props["player"]?.int, let identifier = Int32(exactly: value) else {
            return AnyView(EmptyView())
        }
        return provider(identifier, props["scaling"]?.string, props["controls"]?.string)
    }
}

/// A `Shape` node: the SwiftUI shape, filled or stroked.
struct ShapeNodeView: View {

    let props: [String: PropValue]

    var body: some View {
        switch props["shape"]?.string {
        case "roundedRectangle":
            styled(RoundedRectangle(cornerRadius: Styles.number(props["cornerRadius"])))
        case "circle":
            styled(Circle())
        case "ellipse":
            styled(Ellipse())
        case "capsule":
            styled(Capsule())
        default:
            styled(Rectangle())
        }
    }

    /// `stroke` wins over `fill`; with neither, the foreground color fills it.
    private func styled<S: Shape>(_ shape: S) -> AnyView {
        if let stroke = Styles.color(props["stroke"]) {
            return AnyView(shape.stroke(stroke, lineWidth: Styles.number(props["lineWidth"], 1)))
        }
        if let fill = Styles.color(props["fill"]) {
            return AnyView(shape.fill(fill))
        }
        return AnyView(shape)
    }
}

/// A `DatePicker` node: seconds since 1970 as a `Date`, synced like a
/// control.
struct DatePickerNodeView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let model = self.model
        let store = self.store
        let props = model.node.props
        let selection = Binding<Date>(
            get: { Date(timeIntervalSince1970: model.value?.double ?? 0) },
            set: { store.change(model, to: .double($0.timeIntervalSince1970)) }
        )
        let title = props["title"]?.string ?? ""
        let components = Self.components(props["components"])
        if let range = Self.range(props) {
            DatePicker(title, selection: selection, in: range, displayedComponents: components)
        } else {
            DatePicker(title, selection: selection, displayedComponents: components)
        }
    }

    static func components(_ value: PropValue?) -> DatePickerComponents {
        var components: DatePickerComponents = []
        for name in (value?.string ?? "").split(separator: ",") {
            switch name {
            case "date": components.insert(.date)
            case "hourAndMinute": components.insert(.hourAndMinute)
            default: break
            }
        }
        return components.isEmpty ? [.date, .hourAndMinute] : components
    }

    /// `min...max`, if both are finite and in order.
    static func range(_ props: [String: PropValue]) -> ClosedRange<Date>? {
        guard let lower = props["min"]?.double, let upper = props["max"]?.double,
              lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        return Date(timeIntervalSince1970: lower)...Date(timeIntervalSince1970: upper)
    }
}

/// A `ContextMenu` node: its first child, with the rest as the menu.
struct ContextMenuNodeView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let store = self.store
        let items = Array(model.childIDs.dropFirst())
        ChildView(id: model.childIDs.first, store: store)
            .contextMenu {
                ChildrenView(ids: items, store: store)
            }
    }
}

/// A `Refreshable` node: its child, refreshed by pulling. The indicator
/// stays up until the guest says it's done.
struct RefreshableNodeView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let model = self.model
        let store = self.store
        ChildView(id: model.childIDs.first, store: store)
            .refreshable { await store.refresh(model) }
    }
}
