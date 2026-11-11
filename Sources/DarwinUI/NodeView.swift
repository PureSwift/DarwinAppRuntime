import DarwinHost
import DynamicUI
import SwiftUI

/// Draws one node from its model, and its children through their own
/// models (`SwiftUIRenderer.md` §2, §3).
struct NodeView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let node = model.node
        return node.modifiers.reduce(content(node)) { view, modifier in
            apply(modifier, to: view)
        }
    }

    // MARK: Nodes

    private func content(_ node: RenderNode) -> AnyView {
        let props = node.props
        switch node.type {
        case "Text":
            return AnyView(Text(verbatim: props["text"]?.string ?? ""))

        case "Image":
            return AnyView(image(props))

        case "Label":
            return AnyView(Label(props["title"]?.string ?? "", systemImage: props["systemImage"]?.string ?? ""))

        case "Spacer":
            return AnyView(Spacer(minLength: Styles.length(props["minLength"])))

        case "Divider":
            return AnyView(Divider())

        case "Color":
            return AnyView(Styles.color(props["color"]) ?? .clear)

        case "VStack":
            return AnyView(VStack(alignment: Styles.horizontal(props["alignment"]), spacing: Styles.length(props["spacing"])) {
                children
            })

        case "HStack":
            return AnyView(HStack(alignment: Styles.vertical(props["alignment"]), spacing: Styles.length(props["spacing"])) {
                children
            })

        case "ZStack":
            return AnyView(ZStack(alignment: Styles.alignment(props)) {
                children
            })

        case "ScrollView":
            let axes: Axis.Set
            switch props["axes"]?.string {
            case "horizontal": axes = .horizontal
            case "both": axes = [.horizontal, .vertical]
            default: axes = .vertical
            }
            return AnyView(ScrollView(axes, showsIndicators: props["showsIndicators"]?.bool ?? true) {
                children
            })

        case "Button":
            let id = node.id
            let store = self.store
            return AnyView(Button(action: { store.send(id, .tap) }) {
                children
            })

        case "NavigationLink":
            return AnyView(LinkView(id: node.id, childIDs: model.childIDs, store: store))

        case "Toggle":
            return AnyView(Toggle(isOn: binding(false, \.bool, PropValue.bool)) {
                children
            })

        case "TextField":
            return AnyView(textField(props))

        case "Slider":
            return AnyView(slider(props))

        case "Stepper":
            return AnyView(stepper(props))

        case "ProgressView":
            return AnyView(progress(props))

        case "List":
            return AnyView(list(node))

        case "Section":
            let header = props["header"]?.string.map { Text(verbatim: $0) }
            let footer = props["footer"]?.string.map { Text(verbatim: $0) }
            return AnyView(Section(header: header, footer: footer) {
                children
            })

        case "LazyVStack":
            let alignment = Styles.horizontal(props["alignment"])
            let spacing = Styles.length(props["spacing"])
            if let count = node.count {
                return AnyView(LazyVStack(alignment: alignment, spacing: spacing) {
                    rows(node.id, count: count, revision: props["revision"])
                })
            }
            return AnyView(VStack(alignment: alignment, spacing: spacing) {
                children
            })

        case "LazyHStack":
            let alignment = Styles.vertical(props["alignment"])
            let spacing = Styles.length(props["spacing"])
            if let count = node.count {
                return AnyView(LazyHStack(alignment: alignment, spacing: spacing) {
                    rows(node.id, count: count, revision: props["revision"])
                })
            }
            return AnyView(HStack(alignment: alignment, spacing: spacing) {
                children
            })

        case "NavStack":
            return AnyView(NavStackView(stack: model, store: store))

        case "NavLevel":
            return AnyView(LevelContent(level: model, store: store))

        default:
            UnknownTypes.log(node.type)
            return AnyView(EmptyView())
        }
    }

    private var children: some View {
        ChildrenView(ids: model.childIDs, store: store)
    }

    private func rows(_ list: RenderNode.ID, count: Int, revision: PropValue?) -> some View {
        ForEach(0..<max(0, count), id: \.self) { index in
            LazyRow(list: list, index: index, revision: revision, store: store)
        }
    }

    private func image(_ props: [String: PropValue]) -> some View {
        let image: Image
        if let name = props["systemName"]?.string {
            image = Image(systemName: name)
        } else if let name = props["name"]?.string {
            image = Image(name, bundle: DarwinBundle.bundle)
        } else {
            return AnyView(EmptyView())
        }
        return AnyView(props["resizable"]?.bool == true ? image.resizable() : image)
    }

    private func list(_ node: RenderNode) -> some View {
        let list = List {
            if let count = node.count {
                rows(node.id, count: count, revision: node.props["revision"])
            } else {
                children
            }
        }
        #if os(macOS)
        return list
            .listStyle(InsetListStyle())
            .environment(\.renderInList, true)
        #else
        return list
            .environment(\.renderInList, true)
        #endif
    }

    // MARK: Controls

    /// A binding to the model's control value (§6): reads the local value,
    /// and on write shows the new value and sends `change`.
    private func binding<Value>(
        _ fallback: Value,
        _ read: KeyPath<PropValue, Value?>,
        _ write: @escaping (Value) -> PropValue
    ) -> Binding<Value> {
        let model = self.model
        let store = self.store
        return Binding(
            get: { model.value?[keyPath: read] ?? fallback },
            set: { store.change(model, to: write($0)) }
        )
    }

    private func textField(_ props: [String: PropValue]) -> some View {
        let placeholder = props["placeholder"]?.string ?? ""
        let text = binding("", \.string, PropValue.string)
        let id = model.id
        let store = self.store
        let field: AnyView
        if props["secure"]?.bool == true {
            field = AnyView(SecureField(placeholder, text: text))
        } else {
            field = AnyView(TextField(placeholder, text: text))
        }
        return field.onSubmit { store.send(id, .submit) }
    }

    private func slider(_ props: [String: PropValue]) -> some View {
        let range = Self.range(props["min"]?.double ?? 0, props["max"]?.double ?? 1)
        let value = binding(range.lowerBound, \.double, PropValue.double)
        if let step = props["step"]?.double, step.isFinite, step > 0 {
            return AnyView(Slider(value: value, in: range, step: step))
        }
        return AnyView(Slider(value: value, in: range))
    }

    /// A stepper over the IR's int bounds. Increments clamp without
    /// overflowing, since the guest's default bounds are `Int.min...Int.max`.
    private func stepper(_ props: [String: PropValue]) -> some View {
        let model = self.model
        let store = self.store
        let lower = props["min"]?.int ?? .min
        let upper = max(lower, props["max"]?.int ?? .max)
        let step = max(1, props["step"]?.int ?? 1)
        let current = min(upper, max(lower, model.value?.int ?? lower))
        let increment: (() -> Void)? = current < upper ? {
            let (sum, overflow) = current.addingReportingOverflow(step)
            store.change(model, to: .int(overflow ? upper : min(upper, sum)))
        } : nil
        let decrement: (() -> Void)? = current > lower ? {
            let (difference, overflow) = current.subtractingReportingOverflow(step)
            store.change(model, to: .int(overflow ? lower : max(lower, difference)))
        } : nil
        return Stepper(onIncrement: increment, onDecrement: decrement) {
            children
        }
    }

    private func progress(_ props: [String: PropValue]) -> some View {
        let title = props["title"]?.string
        guard let value = props["value"]?.double, value.isFinite else {
            if let title {
                return AnyView(ProgressView(title))
            }
            return AnyView(ProgressView())
        }
        var total = props["total"]?.double ?? 1
        if !total.isFinite || total <= 0 {
            total = 1
        }
        let clamped = min(total, max(0, value))
        if let title {
            return AnyView(ProgressView(title, value: clamped, total: total))
        }
        return AnyView(ProgressView(value: clamped, total: total))
    }

    /// `min...max`, or `min...min` when they're out of order or not finite.
    static func range(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        let lower = lower.isFinite ? lower : 0
        guard upper.isFinite, upper > lower else { return lower...lower }
        return lower...upper
    }

    // MARK: Modifiers

    /// Applies one modifier (§4). Unknown kinds are ignored.
    private func apply(_ modifier: ModifierNode, to view: AnyView) -> AnyView {
        let args = modifier.args
        switch modifier.kind {
        case "padding":
            return AnyView(view.padding(EdgeInsets(
                top: Styles.number(args["top"]),
                leading: Styles.number(args["leading"]),
                bottom: Styles.number(args["bottom"]),
                trailing: Styles.number(args["trailing"])
            )))

        case "frame":
            let alignment = Styles.alignment(args)
            let flexible = ["minWidth", "idealWidth", "maxWidth", "minHeight", "idealHeight", "maxHeight"]
            if flexible.contains(where: { args[$0] != nil }) {
                return AnyView(view.frame(
                    minWidth: Styles.length(args["minWidth"]),
                    idealWidth: Styles.length(args["idealWidth"]),
                    maxWidth: Styles.flexibleLength(args["maxWidth"]),
                    minHeight: Styles.length(args["minHeight"]),
                    idealHeight: Styles.length(args["idealHeight"]),
                    maxHeight: Styles.flexibleLength(args["maxHeight"]),
                    alignment: alignment
                ))
            }
            return AnyView(view.frame(
                width: Styles.length(args["width"]),
                height: Styles.length(args["height"]),
                alignment: alignment
            ))

        case "offset":
            return AnyView(view.offset(x: Styles.number(args["x"]), y: Styles.number(args["y"])))

        case "background":
            guard let color = Styles.color(args["color"]) else { return view }
            return AnyView(view.background(color))

        case "foregroundColor":
            return AnyView(view.foregroundColor(Styles.color(args["color"])))

        case "tint":
            return AnyView(view.tint(Styles.color(args["color"])))

        case "opacity":
            return AnyView(view.opacity(args["value"]?.double ?? 1))

        case "cornerRadius":
            return AnyView(view.cornerRadius(Styles.number(args["radius"])))

        case "border":
            return AnyView(view.border(Styles.color(args["color"]) ?? .primary, width: Styles.number(args["width"], 1)))

        case "shadow":
            return AnyView(view.shadow(
                color: Styles.color(args["color"]) ?? Color(.sRGBLinear, white: 0, opacity: 0.33),
                radius: Styles.number(args["radius"]),
                x: Styles.number(args["x"]),
                y: Styles.number(args["y"])
            ))

        case "font", "fontWeight", "italic":
            return AnyView(view.modifier(FontModifier(modifier: modifier)))

        case "lineLimit":
            return AnyView(view.lineLimit(args["lines"]?.int.map { max(1, $0) }))

        case "multilineTextAlignment":
            return AnyView(view.multilineTextAlignment(Styles.textAlignment(args["alignment"])))

        case "disabled":
            return AnyView(view.disabled(args["value"]?.bool ?? true))

        case "onTapGesture":
            let id = model.id
            let store = self.store
            return AnyView(view.onTapGesture(count: max(1, args["count"]?.int ?? 1)) {
                store.send(id, .tap)
            })

        case "accessibilityLabel":
            guard let text = args["text"]?.string else { return view }
            return AnyView(view.accessibilityLabel(Text(verbatim: text)))

        case "accessibilityIdentifier":
            guard let identifier = args["identifier"]?.string else { return view }
            return AnyView(view.accessibilityIdentifier(identifier))

        default:
            return view
        }
    }
}

/// A node's children, keyed by node ID, so SwiftUI's identity follows the
/// guest's.
struct ChildrenView: View {

    let ids: [RenderNode.ID]

    let store: RenderStore

    var body: some View {
        ForEach(ids, id: \.self) { id in
            if let model = store.model(id) {
                NodeView(model: model, store: store)
            }
        }
    }
}

/// A `NavigationLink` node: a button styled like a link, with a chevron in
/// a `List`, that sends `tap`. The guest adds the level; the player never
/// pushes on its own (§8).
struct LinkView: View {

    let id: RenderNode.ID

    let childIDs: [RenderNode.ID]

    let store: RenderStore

    @Environment(\.renderInList) private var inList

    var body: some View {
        let id = self.id
        let store = self.store
        if inList {
            Button(action: { store.send(id, .tap) }) {
                HStack {
                    ChildrenView(ids: childIDs, store: store)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Font.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        } else {
            Button(action: { store.send(id, .tap) }) {
                ChildrenView(ids: childIDs, store: store)
            }
        }
    }
}

/// One row of a lazy container (§7): fetched from the guest the first time
/// it's shown, then cached by list ID, index and revision.
struct LazyRow: View {

    let list: RenderNode.ID

    let index: Int

    /// The list's revision. A new one re-evaluates the row, which then
    /// shows the refreshed row.
    let revision: PropValue?

    let store: RenderStore

    var body: some View {
        RowContent(slot: store.row(list, index: index), store: store)
            .onAppear { [store, list, index] in store.rowAppeared(list, index: index) }
            .onDisappear { [store, list, index] in store.rowDisappeared(list, index: index) }
    }
}

private struct RowContent: View {

    @ObservedObject var slot: RowSlot

    let store: RenderStore

    var body: some View {
        if let id = slot.rootID, let model = store.model(id) {
            NodeView(model: model, store: store)
                .id(id)
        }
    }
}

/// Node types without a SwiftUI counterpart here, logged once each.
enum UnknownTypes {

    nonisolated(unsafe) private(set) static var logged: Set<String> = []

    static func log(_ type: String) {
        guard logged.insert(type).inserted else { return }
        AppHost.logger.notice("Unknown node type \(type, privacy: .public); showing nothing")
    }
}
