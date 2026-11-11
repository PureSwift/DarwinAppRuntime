import DynamicUI
import SwiftUI

/// A `NavStack` node (`SwiftUIRenderer.md` §8): its children are its
/// levels, root first.
///
/// The stack shows `RenderStore.shownLevels` levels: the node's level count,
/// or fewer after the user goes back and before the guest answers. Going
/// back sends `pop` with the number of levels left; the guest adds levels,
/// and the player never pushes on its own.
struct NavStackView: View {

    @ObservedObject var stack: NodeModel

    let store: RenderStore

    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            PathStack(stack: stack, store: store)
        } else {
            #if os(iOS)
            NavigationView {
                ChainedLevel(stack: stack, store: store, depth: 0)
            }
            .navigationViewStyle(StackNavigationViewStyle())
            #else
            TopLevel(stack: stack, store: store)
            #endif
        }
    }
}

/// Level `index` of `stack`, or nothing if there isn't one.
struct LevelView: View {

    @ObservedObject var stack: NodeModel

    let index: Int

    let store: RenderStore

    var body: some View {
        let levels = stack.childIDs
        if levels.indices.contains(index), let level = store.model(levels[index]) {
            NodeView(model: level, store: store)
                .id(level.id)
        }
    }
}

/// A `NavLevel`'s content, with its title.
struct LevelContent: View {

    @ObservedObject var level: NodeModel

    let store: RenderStore

    var body: some View {
        let content = VStack(spacing: 8) {
            ChildrenView(ids: level.childIDs, store: store)
        }
        if let title = level.node.props["title"]?.string {
            content.navigationTitle(Text(verbatim: title))
        } else {
            content
        }
    }
}

/// iOS 16+ and macOS 13+: a `NavigationStack` whose path is the shown
/// levels' indices after the root.
@available(iOS 16, macOS 13, *)
private struct PathStack: View {

    @ObservedObject var stack: NodeModel

    let store: RenderStore

    var body: some View {
        let stack = self.stack
        let store = self.store
        let path = Binding<[Int]>(
            get: { Array(1..<store.shownLevels(stack)) },
            set: { path in
                // Only back navigation shortens the path.
                if path.count + 1 < store.shownLevels(stack) {
                    store.pop(stack, to: path.count + 1)
                }
            }
        )
        NavigationStack(path: path) {
            LevelView(stack: stack, index: 0, store: store)
                .navigationDestination(for: Int.self) { index in
                    LevelView(stack: stack, index: index, store: store)
                }
        }
    }
}

#if os(iOS)
/// iOS 15: level `depth`, with a hidden `NavigationLink(isActive:)` to the
/// next. Deactivating the link is the back navigation that sends `pop`.
private struct ChainedLevel: View {

    @ObservedObject var stack: NodeModel

    let store: RenderStore

    let depth: Int

    var body: some View {
        let stack = self.stack
        let store = self.store
        let next = depth + 1
        let isActive = Binding<Bool>(
            get: { store.shownLevels(stack) > next },
            set: { active in
                if !active, store.shownLevels(stack) > next {
                    store.pop(stack, to: next)
                }
            }
        )
        LevelView(stack: stack, index: depth, store: store)
            .background(
                NavigationLink(isActive: isActive) {
                    ChainedLevel(stack: stack, store: store, depth: next)
                } label: {
                    EmptyView()
                }
                .hidden()
            )
    }
}
#endif

#if os(macOS)
/// macOS 12: the top level, with a back button in the toolbar.
/// `NavigationView` there is a split view, not a stack.
private struct TopLevel: View {

    @ObservedObject var stack: NodeModel

    let store: RenderStore

    var body: some View {
        let stack = self.stack
        let store = self.store
        let shown = store.shownLevels(stack)
        LevelView(stack: stack, index: shown - 1, store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if shown > 1 {
                        Button {
                            store.pop(stack, to: shown - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(Text("Back"))
                    }
                }
            }
    }
}
#endif
