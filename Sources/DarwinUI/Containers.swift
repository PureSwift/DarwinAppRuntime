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
