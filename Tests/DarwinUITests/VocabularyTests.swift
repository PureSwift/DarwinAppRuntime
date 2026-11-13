import DynamicUI
import SwiftUI
import Testing
@testable import DarwinUI

/// Pickers, tab views, grids, sheets and alerts (`SwiftUIRenderer.md` §3,
/// §6).
@MainActor
@Suite("Vocabulary")
struct VocabularyTests {

    static var screen: RenderNode {
        RenderNode("VStack", id: 1, children: [
            RenderNode("Picker", id: 2, props: ["title": "Flavor", "selection": 1], children: [text(3, "Vanilla"), text(4, "Chocolate")]),
            RenderNode("Picker", id: 5, props: ["title": "None"], children: [text(6, "Only")]),
            RenderNode("TabView", id: 7, props: ["selection": 0], children: [
                RenderNode("Tab", id: 8, props: ["title": "One"], children: [text(9, "First")]),
                RenderNode("Tab", id: 10, props: ["title": "Two"], children: [text(11, "Second")]),
            ]),
            RenderNode("Sheet", id: 12, props: ["isPresented": true, "style": "sheet"], children: [text(13, "Anchor"), text(14, "Content")]),
            RenderNode("Alert", id: 15, props: ["title": "Sure?", "isPresented": false], children: [
                RenderNode("Button", id: 16, children: [text(17, "Anchor")]),
            ]),
        ])
    }

    @Test func selectionsAreControlValues() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.screen)
        let store = renderer.store
        let picker = try #require(renderer.model(2))
        #expect(picker.value == .int(1))
        #expect(try #require(renderer.model(5)).value == .int(-1), "no selection")

        let selection = selectionBinding(picker, store)
        #expect(selection.wrappedValue == 1)
        selection.wrappedValue = 0
        #expect(selection.wrappedValue == 0, "shown before the guest answers")

        let tabs = selectionBinding(try #require(renderer.model(7)), store)
        tabs.wrappedValue = 1
        #expect(delegate.events == [
            .init(node: 2, kind: .change, payload: .int(0)),
            .init(node: 7, kind: .change, payload: .int(1)),
        ])

        // The guest's answer replaces the local value only when it differs
        // from what it last sent.
        var answered = Self.screen
        answered.children[0].props["selection"] = 0
        renderer.apply(answered)
        #expect(picker.value == .int(0))
    }

    @Test func dismissingSendsChange() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.screen)
        let store = renderer.store
        let sheet = presentedBinding(try #require(renderer.model(12)), store)
        let alert = presentedBinding(try #require(renderer.model(15)), store)
        #expect(sheet.wrappedValue)
        #expect(!alert.wrappedValue)

        alert.wrappedValue = true
        #expect(delegate.events.isEmpty, "only the guest presents")
        sheet.wrappedValue = false
        #expect(!sheet.wrappedValue)
        #expect(delegate.events == [.init(node: 12, kind: .change, payload: .bool(false))])
    }

    @Test func buttonsShowTheirText() {
        let (renderer, _) = makeRenderer()
        renderer.apply(RenderNode("VStack", id: 1, children: [
            RenderNode("Button", id: 2, children: [text(3, "Delete")]),
            RenderNode("Button", id: 4, children: [RenderNode("Label", id: 5, props: ["title": "Share", "systemImage": "square.and.arrow.up"])]),
            RenderNode("Button", id: 6, children: [RenderNode("HStack", id: 7, children: [RenderNode("Image", id: 8, props: ["systemName": "star"]), text(9, "Star")])]),
            RenderNode("Button", id: 10, children: [RenderNode("Image", id: 11, props: ["systemName": "star"])]),
        ]))
        #expect(renderer.store.text(of: 2) == "Delete")
        #expect(renderer.store.text(of: 4) == "Share")
        #expect(renderer.store.text(of: 6) == "Star")
        #expect(renderer.store.text(of: 10) == nil)
        #expect(renderer.store.text(of: 99) == nil)
    }

    @Test func buttonRoles() {
        #expect(Styles.buttonRole("destructive") == .destructive)
        #expect(Styles.buttonRole("cancel") == .cancel)
        #expect(Styles.buttonRole("someFutureRole") == nil)
        #expect(Styles.buttonRole(nil) == nil)
    }

    @Test func gridItems() throws {
        let items = Styles.gridItems(.array([
            .array(["fixed", 40.0, 40.0, 6.0, "leading", "top"]),
            .array(["flexible", 20.0, 10.0]),
            .array(["adaptive", 0.0, .double(.infinity), 2.0, "center", "center"]),
            .array(["someFutureSize", 1.0, 1.0]),
            .array(["fixed"]),
            "notAnItem",
        ]))
        #expect(items.count == 3, "unknown and malformed items are skipped")

        guard case .fixed(let length) = items[0].size else {
            Issue.record("not fixed: \(items[0].size)")
            return
        }
        #expect(length == 40)
        #expect(items[0].spacing == 6)
        #expect(items[0].alignment == .topLeading)

        guard case .flexible(let minimum, let maximum) = items[1].size else {
            Issue.record("not flexible: \(items[1].size)")
            return
        }
        #expect(minimum == 20 && maximum == 20, "the maximum is at least the minimum")
        #expect(items[1].spacing == nil)

        guard case .adaptive(let adaptiveMinimum, let adaptiveMaximum) = items[2].size else {
            Issue.record("not adaptive: \(items[2].size)")
            return
        }
        #expect(adaptiveMinimum == 1, "never zero, which would never end")
        #expect(adaptiveMaximum == .infinity)

        #expect(Styles.gridItems(.array([])).count == 1)
        #expect(Styles.gridItems(nil).count == 1)
    }
}
