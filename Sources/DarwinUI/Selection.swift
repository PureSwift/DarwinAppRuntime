import DynamicUI
import SwiftUI

/// A binding to the index a `Picker` or `TabView` model shows (`RenderIR.md`
/// "Selection"): reads the local value, and on write shows the new index and
/// sends `change`. `-1` is no selection.
func selectionBinding(_ model: NodeModel, _ store: RenderStore) -> Binding<Int> {
    Binding(
        get: { model.value?.int ?? -1 },
        set: { store.change(model, to: .int($0)) }
    )
}

/// A `Picker` node (`SwiftUIRenderer.md` §3, §6): its children are the
/// options, tagged by index.
struct PickerView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let store = self.store
        let options = model.childIDs.compactMap { store.model($0) }
        let picker = Picker(selection: selectionBinding(model, store)) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                NodeView(model: option, store: store)
                    .tag(index)
            }
        } label: {
            Text(verbatim: model.node.props["title"]?.string ?? "")
        }
        switch model.node.props["style"]?.string {
        case "segmented":
            return AnyView(picker.pickerStyle(SegmentedPickerStyle()))
        case "menu":
            return AnyView(picker.pickerStyle(MenuPickerStyle()))
        case "inline":
            return AnyView(picker.pickerStyle(InlinePickerStyle()))
        #if os(iOS)
        case "wheel":
            return AnyView(picker.pickerStyle(WheelPickerStyle()))
        #endif
        default:
            return AnyView(picker)
        }
    }
}

/// A `TabView` node: one tab per `Tab` child, tagged by index.
struct TabsView: View {

    @ObservedObject var model: NodeModel

    let store: RenderStore

    var body: some View {
        let store = self.store
        let tabs = model.childIDs.compactMap { store.model($0) }
        TabView(selection: selectionBinding(model, store)) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabPage(tab: tab, store: store)
                    .tag(index)
            }
        }
    }
}

/// A `Tab` node: its content, with its title and image as the tab item.
private struct TabPage: View {

    @ObservedObject var tab: NodeModel

    let store: RenderStore

    var body: some View {
        let props = tab.node.props
        Group {
            if let id = tab.childIDs.first, let content = store.model(id) {
                NodeView(model: content, store: store)
            } else {
                Color.clear
            }
        }
        .tabItem {
            let title = props["title"]?.string
            let image = props["systemImage"]?.string
            if let title, let image {
                Label(title, systemImage: image)
            } else if let image {
                Image(systemName: image)
            } else {
                Text(verbatim: title ?? "")
            }
        }
    }
}
