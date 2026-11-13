import Combine
import DarwinHost
import DynamicUI
import Foundation

/// One node's state: the node without its children's content, and, for a
/// control, the value it shows (`SwiftUIRenderer.md` §2, §6).
///
/// `NodeView` observes only its own model, so an update re-evaluates only
/// the views whose nodes changed.
final class NodeModel: ObservableObject, Identifiable {

    let id: RenderNode.ID

    /// The node, with each child reduced to its type and ID.
    @Published private(set) var node: RenderNode

    /// What a control shows: the user's last input, or the guest's value
    /// when it differs from `rendered`. `nil` for other nodes.
    @Published fileprivate(set) var value: PropValue?

    /// The control value of the last node this model showed.
    private(set) var rendered: PropValue?

    init(_ node: RenderNode) {
        self.id = node.id
        self.node = node
        let incoming = Self.controlValue(of: node)
        self.value = incoming
        self.rendered = incoming
    }

    /// The children's IDs, in order.
    var childIDs: [RenderNode.ID] {
        node.children.map(\.id)
    }

    /// Takes a new node for this ID. Publishes only if it differs.
    ///
    /// The control value is replaced only when the node's value differs
    /// from `rendered`, so a guest that echoes the user's input doesn't
    /// reset what the user is typing or dragging, and a guest that changes
    /// the value wins.
    fileprivate func update(_ new: RenderNode) {
        let typeChanged = new.type != node.type
        if new != node {
            node = new
        }
        let incoming = Self.controlValue(of: new)
        if typeChanged || incoming != rendered {
            rendered = incoming
            if value != incoming {
                value = incoming
            }
        }
    }

    /// The user's input, before it's sent to the guest.
    fileprivate func setLocal(_ new: PropValue) {
        if value != new {
            value = new
        }
    }

    /// The prop a control's value is in. A `NavStack`'s value is how many
    /// levels it shows; a `Picker`'s or `TabView`'s the selected index, `-1`
    /// for none; a `Sheet`'s or `Alert`'s whether it's presented; a
    /// `DisclosureGroup`'s whether it's expanded; a `Searchable`'s its text.
    static func controlValue(of node: RenderNode) -> PropValue? {
        switch node.type {
        case "Toggle": return node.props["isOn"]
        case "TextField", "Searchable": return node.props["text"]
        case "DisclosureGroup": return node.props["isExpanded"] ?? false
        case "Slider", "Stepper": return node.props["value"]
        case "NavStack": return .int(node.children.count)
        case "Picker", "TabView": return node.props["selection"] ?? .int(-1)
        case "Sheet", "Alert": return node.props["isPresented"] ?? false
        default: return nil
        }
    }
}

/// The rows of a lazy container that the player has fetched, one per index
/// (`SwiftUIRenderer.md` §7).
final class RowSlot: ObservableObject {

    let list: RenderNode.ID

    let index: Int

    /// The row's root node, or `nil` if the guest had no row.
    @Published fileprivate(set) var rootID: RenderNode.ID?

    /// The list's `revision` when the row was fetched.
    fileprivate(set) var revision: PropValue?

    /// Every node ID in the row's subtree.
    fileprivate(set) var ids: Set<RenderNode.ID> = []

    init(list: RenderNode.ID, index: Int) {
        self.list = list
        self.index = index
    }
}

/// Every node on screen, by ID, and the rows fetched for lazy containers
/// (`SwiftUIRenderer.md` §2). Main thread only.
final class RenderStore: ObservableObject {

    /// The guest. Events and row requests go to it.
    let delegate: any RendererDelegate

    /// The root of the last applied tree.
    @Published private(set) var rootID: RenderNode.ID?

    private(set) var models: [RenderNode.ID: NodeModel] = [:]

    /// Each node's parent in its tree. A row's root has none.
    private var parents: [RenderNode.ID: RenderNode.ID] = [:]

    /// Roots of subtrees whose models outlive their removal, until
    /// `release`: a sheet's content, shown while the sheet slides away.
    private var held: Set<RenderNode.ID> = []

    /// Models of held subtrees the guest removed, by ID.
    private var retired: [RenderNode.ID: NodeModel] = [:]

    /// Fetched rows, by list ID, then index.
    private var rows: [RenderNode.ID: [Int: RowSlot]] = [:]

    /// The rows on screen, by list ID, from their views' appearance.
    private var visibleRows: [RenderNode.ID: Set<Int>] = [:]

    private var refreshScheduled = false

    /// Runs the refresh of stale rows after the current update. Replaceable
    /// in tests.
    var schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    init(delegate: any RendererDelegate) {
        self.delegate = delegate
    }

    /// The model of a node on screen, or of a removed node in a held
    /// subtree.
    func model(_ id: RenderNode.ID) -> NodeModel? {
        models[id] ?? retired[id]
    }

    /// Keeps the models of the subtree at `id` after the guest removes it,
    /// until `release(id)`.
    func hold(_ id: RenderNode.ID) {
        held.insert(id)
    }

    /// Lets go of the subtree at `id`, and drops it if the guest removed it.
    func release(_ id: RenderNode.ID) {
        held.remove(id)
        var pending = [id]
        while let next = pending.popLast() {
            guard models[next] == nil, let model = retired.removeValue(forKey: next) else { continue }
            pending.append(contentsOf: model.childIDs)
            if rows[next] != nil || visibleRows[next] != nil {
                dropRows(of: next)
            }
        }
    }

    // MARK: Updates

    /// Replaces everything: keeps the model of every ID still present,
    /// updates the ones whose node changed, and drops the rest.
    func apply(_ tree: RenderNode) {
        let old = rootID.map(treeIDs) ?? []
        var new = Set<RenderNode.ID>()
        upsert(tree, parent: nil, into: &new)
        remove(old.filter { !new.contains($0) })
        if rootID != tree.id {
            rootID = tree.id
        }
    }

    /// Replaces the node `id` and its subtree, the same way as `apply`.
    /// Returns whether `id` was on screen.
    @discardableResult
    func replaceSubtree(_ id: RenderNode.ID, with tree: RenderNode) -> Bool {
        guard models[id] != nil else {
            AppHost.logger.error("replaceSubtree: no node \(id, privacy: .public) on screen")
            return false
        }
        let parent = parents[id]
        let slot = owningSlot(of: id)
        let old = treeIDs(id)
        var new = Set<RenderNode.ID>()
        upsert(tree, parent: parent, into: &new)
        remove(old.filter { !new.contains($0) })
        if let slot {
            slot.ids.subtract(old)
            slot.ids.formUnion(new)
        }
        guard tree.id != id else { return true }
        // A new root ID: point whatever referred to the old one at it.
        if let parent, let model = models[parent] {
            var node = model.node
            for index in node.children.indices where node.children[index].id == id {
                node.children[index] = tree.shallow
            }
            model.update(node)
        } else if rootID == id {
            rootID = tree.id
        } else if let slot, slot.rootID == id {
            slot.rootID = tree.id
        }
        return true
    }

    /// Creates or updates the model for each node in `node`'s subtree.
    private func upsert(_ node: RenderNode, parent: RenderNode.ID?, into ids: inout Set<RenderNode.ID>) {
        ids.insert(node.id)
        let shallow = node.shallow
        if let model = models[node.id] {
            let before = model.node
            model.update(shallow)
            if shallow.count == nil {
                if rows[node.id] != nil {
                    dropRows(of: node.id)
                }
            } else if before.type != shallow.type
                || before.count != shallow.count
                || before.props["revision"] != shallow.props["revision"] {
                invalidateRows(of: node.id)
            }
        } else {
            models[node.id] = NodeModel(shallow)
        }
        parents[node.id] = parent
        for child in node.children {
            upsert(child, parent: node.id, into: &ids)
        }
    }

    /// The IDs in the subtree at `id`, rows of lazy containers excluded.
    private func treeIDs(_ id: RenderNode.ID) -> [RenderNode.ID] {
        var ids: [RenderNode.ID] = []
        var pending = [id]
        while let next = pending.popLast() {
            guard let model = models[next] else { continue }
            ids.append(next)
            pending.append(contentsOf: model.childIDs)
        }
        return ids
    }

    /// Drops the models of `ids`, which the guest removed. Those in a held
    /// subtree are retired instead, with their rows.
    private func remove(_ ids: [RenderNode.ID]) {
        var retiring = Set<RenderNode.ID>()
        for root in held where ids.contains(root) {
            retiring.formUnion(treeIDs(root))
        }
        for id in ids {
            if retiring.contains(id), let model = models[id] {
                retired[id] = model
                models[id] = nil
                parents[id] = nil
            } else {
                remove(id)
            }
        }
    }

    private func remove(_ id: RenderNode.ID) {
        models[id] = nil
        parents[id] = nil
        if rows[id] != nil || visibleRows[id] != nil {
            dropRows(of: id)
        }
    }

    // MARK: Lazy rows

    /// The list's current revision. Rows fetched at another one are stale.
    private func revision(of list: RenderNode.ID) -> PropValue? {
        model(list)?.node.props["revision"]
    }

    /// Row `index` of the lazy container `list`. Fetches it from the guest
    /// the first time; a row fetched at an older revision is returned as it
    /// is and refreshed after the current update.
    func row(_ list: RenderNode.ID, index: Int) -> RowSlot {
        if let slot = rows[list]?[index] {
            if slot.revision != revision(of: list) {
                scheduleRefresh()
            }
            return slot
        }
        let slot = RowSlot(list: list, index: index)
        rows[list, default: [:]][index] = slot
        fetch(slot)
        return slot
    }

    /// Whether row `index` of `list` has been fetched at the list's current
    /// revision.
    func hasRow(_ list: RenderNode.ID, index: Int) -> Bool {
        guard let slot = rows[list]?[index] else { return false }
        return slot.revision == revision(of: list)
    }

    func rowAppeared(_ list: RenderNode.ID, index: Int) {
        guard model(list) != nil else { return }
        visibleRows[list, default: []].insert(index)
    }

    func rowDisappeared(_ list: RenderNode.ID, index: Int) {
        visibleRows[list]?.remove(index)
    }

    /// Fetches again every row on screen whose list has a new revision.
    func refreshStaleRows() {
        refreshScheduled = false
        for (list, slots) in rows {
            let current = revision(of: list)
            for slot in slots.values where slot.revision != current {
                fetch(slot)
            }
        }
    }

    private func fetch(_ slot: RowSlot) {
        let bytes = delegate.row(RenderCodec.encode(id: slot.list), index: Int32(truncatingIfNeeded: slot.index))
        var tree: RenderNode?
        if !bytes.isEmpty {
            do {
                tree = try RenderCodec.decode(bytes)
            } catch {
                AppHost.logger.error("Row \(slot.index, privacy: .public) of \(slot.list, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        var new = Set<RenderNode.ID>()
        if let tree {
            upsert(tree, parent: nil, into: &new)
        }
        // A row that moved to another index is that row's now.
        for id in slot.ids where !new.contains(id) && !isInAnotherRow(id, than: slot) {
            remove(id)
        }
        slot.ids = new
        slot.revision = revision(of: slot.list)
        if slot.rootID != tree?.id {
            slot.rootID = tree?.id
        }
    }

    /// A list's revision or count changed: drops the rows that aren't on
    /// screen and refreshes the rest after the current update.
    private func invalidateRows(of list: RenderNode.ID) {
        guard let slots = rows[list] else { return }
        let count = models[list]?.node.count ?? 0
        let visible = visibleRows[list] ?? []
        for (index, slot) in slots where index >= count || !visible.contains(index) {
            rows[list]?[index] = nil
            for id in slot.ids where !isInAnotherRow(id, than: slot) {
                remove(id)
            }
        }
        if rows[list]?.isEmpty == false {
            scheduleRefresh()
        }
    }

    /// Drops every row of `list` and the models in them.
    private func dropRows(of list: RenderNode.ID) {
        let slots = rows.removeValue(forKey: list) ?? [:]
        visibleRows[list] = nil
        for slot in slots.values {
            for id in slot.ids {
                remove(id)
            }
        }
    }

    /// Whether a fetched row other than `slot` has the node `id`: rows
    /// whose items moved share IDs until each is refreshed.
    private func isInAnotherRow(_ id: RenderNode.ID, than slot: RowSlot) -> Bool {
        rows.values.contains { slots in
            slots.values.contains { $0 !== slot && $0.ids.contains(id) }
        }
    }

    /// The row whose subtree contains `id`, if any.
    private func owningSlot(of id: RenderNode.ID) -> RowSlot? {
        var top = id
        while let parent = parents[top] {
            top = parent
        }
        guard top != rootID else { return nil }
        for slots in rows.values {
            for slot in slots.values where slot.rootID == top {
                return slot
            }
        }
        return nil
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        schedule { [weak self] in
            self?.refreshStaleRows()
        }
    }

    // MARK: Events

    /// Sends an event to the guest. The guest's answer arrives as an update
    /// before this returns.
    func send(_ id: RenderNode.ID, _ kind: RenderEventKind, _ payload: PropValue? = nil) {
        delegate.event(
            RenderCodec.encode(id: id),
            kind: kind.rawValue,
            payload: payload.map { RenderCodec.encode(payload: $0) } ?? []
        )
    }

    /// The text a node shows: a `Text`'s, a `Label`'s title, or its first
    /// descendant's. For labels that must be plain text, such as an alert's
    /// buttons.
    func text(of id: RenderNode.ID) -> String? {
        guard let model = models[id] else { return nil }
        switch model.node.type {
        case "Text":
            return model.node.props["text"]?.string
        case "Label":
            return model.node.props["title"]?.string
        default:
            return model.childIDs.lazy.compactMap { self.text(of: $0) }.first
        }
    }

    /// The user changed a control: shows the new value and sends `change`.
    func change(_ model: NodeModel, to value: PropValue) {
        guard model.value != value else { return }
        model.setLocal(value)
        send(model.id, .change, value)
    }

    /// How many levels a `NavStack` shows: at least one, at most its
    /// levels.
    func shownLevels(_ stack: NodeModel) -> Int {
        let levels = stack.node.children.count
        let shown = stack.value?.int ?? levels
        return max(1, min(shown, levels))
    }

    /// The user went back in a `NavStack`: shows `left` levels and sends
    /// `pop` with that number.
    func pop(_ stack: NodeModel, to left: Int) {
        guard left >= 1, left < shownLevels(stack) else { return }
        stack.setLocal(.int(left))
        send(stack.id, .pop, .int(left))
    }
}

extension RenderNode {

    /// The node with each child reduced to its type and ID.
    var shallow: RenderNode {
        var node = self
        node.children = children.map { RenderNode($0.type, id: $0.id) }
        return node
    }
}
