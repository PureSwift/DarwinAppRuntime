import DynamicUI
import Testing
@testable import DarwinUI

@MainActor
@Suite("Events and control sync")
struct EventTests {

    static func field(_ value: String) -> RenderNode {
        RenderNode("TextField", id: 2, props: ["text": .string(value), "placeholder": "Name"])
    }

    static func form(_ value: String, greeting: String = "Hello") -> RenderNode {
        RenderNode("VStack", id: 1, children: [field(value), text(3, greeting)])
    }

    @Test func tapSendsIDAndKind() {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(RenderNode("Button", id: 0xDEAD_BEEF_0000_0001, children: [text(2, "+")]))
        renderer.store.send(0xDEAD_BEEF_0000_0001, .tap)
        #expect(delegate.events == [.init(node: 0xDEAD_BEEF_0000_0001, kind: .tap, payload: nil)])
    }

    @Test func controlsSendTheirValues() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(RenderNode("VStack", id: 1, children: [
            RenderNode("Toggle", id: 2, props: ["isOn": false], children: [text(3, "On")]),
            Self.field(""),
            RenderNode("Slider", id: 4, props: ["value": 0.5, "min": 0.0, "max": 1.0]),
            RenderNode("Stepper", id: 5, props: ["value": 1, "min": 0, "max": 10, "step": 1], children: [text(6, "Count")]),
        ]))
        let store = renderer.store
        store.change(try #require(renderer.model(2)), to: .bool(true))
        store.change(try #require(renderer.model(2)), to: .bool(true))
        store.change(try #require(renderer.model(4)), to: .double(0.75))
        store.change(try #require(renderer.model(5)), to: .int(2))
        store.send(2, .submit)
        #expect(delegate.events == [
            .init(node: 2, kind: .change, payload: .bool(true)),
            .init(node: 4, kind: .change, payload: .double(0.75)),
            .init(node: 5, kind: .change, payload: .int(2)),
            .init(node: 2, kind: .submit, payload: nil),
        ])
    }

    /// Typing in a field the guest echoes: the local value is never reset.
    @Test func echoKeepsTheLocalValue() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.form(""))
        delegate.onEvent = { event in
            // The guest's answer, before the event call returns.
            let typed = event.payload?.string ?? ""
            renderer.replace(1, with: Self.form(typed, greeting: "Hello, \(typed)"))
        }
        let model = try #require(renderer.model(2))
        let counter = PublishCounter(model)

        for typed in ["a", "ab", "abc"] {
            renderer.store.change(model, to: .string(typed))
            #expect(model.value == .string(typed))
            #expect(model.rendered == .string(typed))
        }
        #expect(delegate.events.map(\.payload) == ["a", "ab", "abc"])
        #expect(renderer.model(3)?.node.props["text"] == "Hello, abc")
        // One publish for the input and one for the node per keystroke;
        // the echo doesn't set the value again.
        #expect(counter.count == 6)
    }

    /// A guest that changes the value (clamps, filters) wins.
    @Test func clampWins() throws {
        let (renderer, delegate) = makeRenderer()
        let slider = { (value: Double) in RenderNode("Slider", id: 4, props: ["value": .double(value), "min": 0.0, "max": 1.0]) }
        renderer.apply(slider(0.5))
        delegate.onEvent = { event in
            renderer.apply(slider(min(0.8, event.payload?.double ?? 0)))
        }
        let model = try #require(renderer.model(4))
        renderer.store.change(model, to: .double(0.9))
        #expect(model.value == .double(0.8))
        #expect(model.rendered == .double(0.8))

        // A field that drops characters it doesn't accept.
        renderer.apply(Self.form("12"))
        delegate.onEvent = { event in
            let digits = (event.payload?.string ?? "").filter(\.isNumber)
            renderer.replace(2, with: Self.field(digits))
        }
        let field = try #require(renderer.model(2))
        renderer.store.change(field, to: .string("123x"))
        #expect(field.value == .string("123"))
    }

    /// A guest that ignores the value sends nothing, or the value it last
    /// rendered: the user's input stays.
    @Test func ignoredValueKeepsTheLocalValue() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.form("Ada"))
        let model = try #require(renderer.model(2))

        renderer.store.change(model, to: .string("Adam"))
        #expect(delegate.events.count == 1)
        #expect(model.value == .string("Adam"))

        // An unrelated update with the value as last rendered.
        renderer.apply(Self.form("Ada", greeting: "Hi"))
        #expect(model.value == .string("Adam"))
        #expect(renderer.model(3)?.node.props["text"] == "Hi")

        // A new value from the guest replaces it.
        renderer.apply(Self.form("Grace"))
        #expect(model.value == .string("Grace"))
    }

    @Test func toggleFollowsTheGuest() throws {
        let (renderer, delegate) = makeRenderer()
        let toggle = { (isOn: Bool) in RenderNode("Toggle", id: 2, props: ["isOn": .bool(isOn)], children: [text(3, "On")]) }
        renderer.apply(toggle(false))
        delegate.onEvent = { event in renderer.apply(toggle(event.payload?.bool ?? false)) }
        let model = try #require(renderer.model(2))
        renderer.store.change(model, to: .bool(true))
        #expect(model.value == .bool(true))
        renderer.apply(toggle(false))
        #expect(model.value == .bool(false), "the guest turned it off")
    }

    @Test func eventsFromLazyRowsUseTheirNodeIDs() {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { _, index in RenderStoreTests.fruitRow(index) }
        renderer.apply(RenderStoreTests.list(revision: 1))
        _ = renderer.store.row(10, index: 1)
        renderer.store.send(112, .tap)
        #expect(delegate.events == [.init(node: 112, kind: .tap, payload: nil)])
    }
}

@MainActor
@Suite("Navigation")
struct NavigationTests {

    static func stack(_ titles: [String]) -> RenderNode {
        RenderNode("NavStack", id: 1, children: titles.enumerated().map { depth, title in
            RenderNode("NavLevel", id: RenderNode.ID(10 + depth), props: ["title": .string(title)], children: [
                RenderNode("NavigationLink", id: RenderNode.ID(20 + depth), children: [text(RenderNode.ID(30 + depth), "Next")]),
            ])
        })
    }

    @Test func popSendsTheLevelsLeft() throws {
        let (renderer, delegate) = makeRenderer()
        let titles = ["Example", "Banana", "Detail"]
        renderer.apply(Self.stack(titles))
        delegate.onEvent = { event in
            if event.kind == .pop, let left = event.payload?.int {
                renderer.replace(1, with: Self.stack(Array(titles.prefix(left))))
            }
        }
        let stack = try #require(renderer.model(1))
        #expect(renderer.store.shownLevels(stack) == 3)

        renderer.store.pop(stack, to: 1)
        #expect(delegate.events == [.init(node: 1, kind: .pop, payload: .int(1))])
        #expect(renderer.store.shownLevels(stack) == 1)
        #expect(stack.childIDs == [10])
        #expect(renderer.model(11) == nil)
    }

    @Test func pushFollowsTheGuest() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.stack(["Example"]))
        delegate.onEvent = { event in
            if event.kind == .tap, event.node == 20 {
                renderer.replace(1, with: Self.stack(["Example", "Banana"]))
            }
        }
        let stack = try #require(renderer.model(1))
        renderer.store.send(20, .tap)
        #expect(renderer.store.shownLevels(stack) == 2)
        #expect(renderer.model(11)?.node.props["title"] == "Banana")
    }

    /// Until the guest answers, the stack shows what the user went back to.
    @Test func ignoredPopShowsTheLevelsLeft() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.stack(["Example", "Banana"]))
        let stack = try #require(renderer.model(1))
        renderer.store.pop(stack, to: 1)
        #expect(delegate.events.count == 1)
        #expect(renderer.store.shownLevels(stack) == 1)

        // Nothing to pop at the root.
        renderer.store.pop(stack, to: 1)
        renderer.store.pop(stack, to: 0)
        #expect(delegate.events.count == 1)

        // The guest pushes again.
        renderer.apply(Self.stack(["Example", "Banana", "Detail"]))
        #expect(renderer.store.shownLevels(stack) == 3)
    }
}
