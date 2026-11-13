import DynamicUI
import SwiftUI

/// A binding to whether a `Sheet` or `Alert` model is presented (`RenderIR.md`
/// "Presentations"). SwiftUI only ever sets it to `false`, when the
/// presentation goes away: that shows it gone and sends `change`.
func presentedBinding(_ model: NodeModel, _ store: RenderStore) -> Binding<Bool> {
    Binding(
        get: { model.value?.bool ?? false },
        set: { presented in
            if !presented {
                store.change(model, to: .bool(false))
            }
        }
    )
}

/// The node `id`, or nothing.
struct ChildView: View {

    let id: RenderNode.ID?

    let store: RenderStore

    var body: some View {
        if let id, let model = store.model(id) {
            NodeView(model: model, store: store)
        }
    }
}

/// A `Sheet` node (`SwiftUIRenderer.md` §3, §6): its first child, presenting
/// the second while `isPresented`.
struct SheetView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let model = self.model
        let store = self.store
        let presented = presentedBinding(model, store)
        let anchor = ChildView(id: model.childIDs.first, store: store)
        #if os(iOS)
        if model.node.props["style"]?.string == "fullScreenCover" {
            anchor.fullScreenCover(isPresented: presented) {
                SheetContent(sheet: model, store: store)
            }
        } else {
            anchor.sheet(isPresented: presented) {
                SheetContent(sheet: model, store: store)
            }
        }
        #else
        // macOS: sheets size to their content, and close with Escape.
        anchor.sheet(isPresented: presented) {
            SheetContent(sheet: model, store: store)
                .frame(minWidth: 320, minHeight: 240)
                .onExitCommand { presented.wrappedValue = false }
        }
        #endif
    }
}

/// A sheet's content: the `Sheet` node's second child.
private struct SheetContent: View {

    @ObservedObject var sheet: NodeModel

    let store: RenderStore

    var body: some View {
        let children = sheet.childIDs
        ChildView(id: children.count > 1 ? children[1] : nil, store: store)
    }
}

/// An `Alert` node: its first child, presenting an alert with the other
/// children as buttons while `isPresented`.
struct AlertView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let store = self.store
        let props = model.node.props
        let actions = model.childIDs.dropFirst().compactMap { store.model($0) }
        ChildView(id: model.childIDs.first, store: store)
            .alert(Text(verbatim: props["title"]?.string ?? ""), isPresented: presentedBinding(model, store)) {
                ForEach(actions) { action in
                    AlertButton(model: action, store: store)
                }
            } message: {
                if let message = props["message"]?.string {
                    Text(verbatim: message)
                }
            }
    }
}

/// An alert's `Button` node, as a system alert button: its text and role.
private struct AlertButton: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let id = model.id
        let store = self.store
        Button(role: Styles.buttonRole(model.node.props["role"])) {
            store.send(id, .tap)
        } label: {
            Text(verbatim: store.text(of: id) ?? "")
        }
    }
}
