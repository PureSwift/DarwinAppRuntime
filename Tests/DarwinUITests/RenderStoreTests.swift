import Combine
import DynamicUI
import Testing
@testable import DarwinUI

/// Counts a model's publishes.
final class PublishCounter {

    private(set) var count = 0

    private var cancellable: AnyCancellable?

    init(_ object: some ObservableObject) {
        cancellable = object.objectWillChange.sink { [unowned self] _ in count += 1 }
    }
}

@MainActor
@Suite("RenderStore")
struct RenderStoreTests {

    static func screen(count: String = "0", extra: Bool = false) -> RenderNode {
        var children = [
            text(2, "Hello"),
            RenderNode("HStack", id: 3, props: ["alignment": "center", "spacing": 8.0], children: [
                text(4, count),
                RenderNode("Button", id: 5, children: [text(6, "+")]),
            ]),
        ]
        if extra {
            children.append(text(7, "Extra"))
        }
        return RenderNode("VStack", id: 1, props: ["alignment": "center", "spacing": 8.0], children: children)
    }

    @Test func applyKeepsModelsForSurvivingIDs() throws {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen(extra: true))
        #expect(renderer.store.rootID == 1)
        #expect(renderer.store.models.count == 7)
        let hello = try #require(renderer.model(2))
        let count = try #require(renderer.model(4))
        let root = try #require(renderer.model(1))
        #expect(root.childIDs == [2, 3, 7])
        // Children are referenced by ID, without their content.
        #expect(root.node.children.allSatisfy { $0.props.isEmpty && $0.children.isEmpty })

        renderer.apply(Self.screen(count: "1"))
        #expect(renderer.model(2) === hello)
        #expect(renderer.model(4) === count)
        #expect(renderer.model(1) === root)
        #expect(count.node.props["text"] == "1")
        #expect(renderer.model(7) == nil, "dropped the removed node")
        #expect(root.childIDs == [2, 3])
    }

    @Test func applyWithNewRootReplacesEverything() {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        renderer.apply(text(9, "Other"))
        #expect(renderer.store.rootID == 9)
        #expect(renderer.store.models.count == 1)
    }

    @Test func unchangedNodesDontPublish() throws {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        let counters = try (1...6).map { PublishCounter(try #require(renderer.model($0))) }
        renderer.apply(Self.screen())
        #expect(counters.map(\.count) == [0, 0, 0, 0, 0, 0])

        renderer.apply(Self.screen(count: "1"))
        #expect(counters.map(\.count) == [0, 0, 0, 1, 0, 0], "only the changed text published")
    }

    @Test func replaceSubtreeKeepsModelsForSurvivingIDs() throws {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        let row = try #require(renderer.model(3))
        let button = try #require(renderer.model(5))
        let counters = try (1...6).map { PublishCounter(try #require(renderer.model($0))) }

        renderer.replace(4, with: text(4, "1"))
        #expect(renderer.model(4)?.node.props["text"] == "1")
        #expect(counters.map(\.count) == [0, 0, 0, 1, 0, 0])

        // A new child in the row: the row publishes, its other children don't.
        renderer.replace(3, with: RenderNode("HStack", id: 3, props: ["alignment": "center", "spacing": 8.0], children: [
            text(4, "1"),
            RenderNode("Button", id: 5, children: [text(6, "+")]),
            text(8, "!"),
        ]))
        #expect(renderer.model(3) === row)
        #expect(renderer.model(5) === button)
        #expect(row.childIDs == [4, 5, 8])
        #expect(renderer.model(8) != nil)
        #expect(counters.map(\.count) == [0, 0, 1, 1, 0, 0])

        // Removing a child drops its model.
        renderer.replace(3, with: RenderNode("HStack", id: 3, props: ["alignment": "center", "spacing": 8.0], children: [text(4, "1")]))
        #expect(renderer.model(5) == nil)
        #expect(renderer.model(6) == nil)
        #expect(renderer.model(8) == nil)
        #expect(renderer.store.models.count == 4)
    }

    @Test func replaceSubtreeWithNewIDUpdatesItsParent() throws {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        renderer.replace(2, with: text(20, "Hi"))
        #expect(renderer.model(1)?.childIDs == [20, 3])
        #expect(renderer.model(2) == nil)
        #expect(renderer.model(20)?.node.props["text"] == "Hi")
    }

    @Test func replaceSubtreeOfUnknownNodeIsIgnored() {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        renderer.replace(99, with: text(99, "?"))
        #expect(renderer.model(99) == nil)
        #expect(renderer.store.models.count == 6)
    }

    @Test func badBytesAreIgnored() {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen())
        renderer.apply([0, 1, 2])
        renderer.replaceSubtree([1], tree: RenderCodec.encode(text(2, "x")))
        #expect(renderer.store.rootID == 1)
        #expect(renderer.model(2)?.node.props["text"] == "Hello")
    }

    // MARK: Lazy rows

    static func list(revision: Int, count: Int = 3) -> RenderNode {
        RenderNode("List", id: 10, props: ["revision": .int(revision)], count: count)
    }

    static func fruitRow(_ index: Int, liked: Int = 0) -> RenderNode {
        let id = RenderNode.ID(100 + index * 10)
        return RenderNode("HStack", id: id, children: [
            text(id + 1, ["Apple", "Banana", "Cherry"][index]),
            RenderNode("Button", id: id + 2, children: [text(id + 3, "Like (\(liked))")]),
        ])
    }

    @Test func rowsAreCachedByListIndexAndRevision() throws {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { list, index in
            #expect(list == 10)
            return Self.fruitRow(index)
        }
        let store = renderer.store
        renderer.apply(Self.list(revision: 1))

        let slot = store.row(10, index: 1)
        #expect(slot.rootID == 110)
        #expect(store.model(111)?.node.props["text"] == "Banana")
        #expect(delegate.rowRequests.count == 1)

        // Cached.
        #expect(store.row(10, index: 1) === slot)
        #expect(delegate.rowRequests.count == 1)

        // A new revision drops rows that aren't on screen, with their models.
        renderer.apply(Self.list(revision: 2))
        #expect(store.hasRow(10, index: 1) == false)
        #expect(store.model(111) == nil)
        _ = store.row(10, index: 1)
        #expect(delegate.rowRequests.count == 2)
        #expect(store.model(111) != nil)
    }

    @Test func rowsOnScreenRefreshKeepingModels() throws {
        let (renderer, delegate) = makeRenderer()
        var liked = 0
        delegate.rows = { _, index in Self.fruitRow(index, liked: liked) }
        let store = renderer.store
        var refreshes: [() -> Void] = []
        store.schedule = { refreshes.append($0) }
        renderer.apply(Self.list(revision: 1))

        let slot = store.row(10, index: 0)
        store.rowAppeared(10, index: 0)
        _ = store.row(10, index: 2)
        let label = try #require(store.model(103))
        let counter = PublishCounter(label)

        liked = 1
        renderer.apply(Self.list(revision: 2))
        // The row on screen is stale until the refresh; the other is gone.
        #expect(store.hasRow(10, index: 0) == false)
        #expect(store.model(103) === label)
        #expect(store.model(121) == nil)
        #expect(refreshes.count == 1)

        refreshes.forEach { $0() }
        #expect(store.hasRow(10, index: 0))
        #expect(store.row(10, index: 0) === slot)
        #expect(store.model(103) === label, "kept the model of a surviving ID")
        #expect(label.node.props["text"] == "Like (1)")
        #expect(counter.count == 1)
        #expect(delegate.rowRequests.map(\.index) == [0, 2, 0])
    }

    /// Rows on screen whose items swap places: each row's refresh finds its
    /// new item's nodes in the other row, and neither loses them.
    @Test func rowsThatTradePlacesKeepTheirModels() throws {
        let (renderer, delegate) = makeRenderer()
        var order = [0, 1, 2]
        delegate.rows = { _, index in Self.fruitRow(order[index]) }
        let store = renderer.store
        var refreshes: [() -> Void] = []
        store.schedule = { refreshes.append($0) }
        renderer.apply(Self.list(revision: 1))
        for index in 0..<3 {
            _ = store.row(10, index: index)
            store.rowAppeared(10, index: index)
        }

        order = [2, 1, 0]
        renderer.apply(Self.list(revision: 2))
        refreshes.forEach { $0() }
        for index in 0..<3 {
            let slot = store.row(10, index: index)
            let root = try #require(slot.rootID)
            #expect(root == RenderNode.ID(100 + order[index] * 10))
            #expect(store.model(root) != nil, "row \(index)")
            #expect(store.model(root + 1)?.node.props["text"] == .string(["Apple", "Banana", "Cherry"][order[index]]))
        }
    }

    @Test func rowsBeyondANewCountAreDropped() {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { _, index in Self.fruitRow(index) }
        let store = renderer.store
        renderer.apply(Self.list(revision: 1))
        _ = store.row(10, index: 2)
        store.rowAppeared(10, index: 2)
        renderer.apply(Self.list(revision: 2, count: 2))
        #expect(store.model(120) == nil)
    }

    @Test func removingAListDropsItsRows() {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { _, index in Self.fruitRow(index) }
        let store = renderer.store
        renderer.apply(RenderNode("VStack", id: 1, children: [Self.list(revision: 1)]))
        _ = store.row(10, index: 0)
        store.rowAppeared(10, index: 0)
        #expect(store.model(100) != nil)

        renderer.replace(1, with: RenderNode("VStack", id: 1, children: [text(2, "Empty")]))
        #expect(store.model(10) == nil)
        #expect(store.model(100) == nil)
        #expect(store.model(101) == nil)
        #expect(store.models.count == 2)
    }

    @Test func missingRowIsEmpty() {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.list(revision: 1))
        let slot = renderer.store.row(10, index: 0)
        #expect(slot.rootID == nil)
    }
}
