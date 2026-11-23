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

    /// A sheet's content stays while the sheet slides away, after the guest
    /// removed it.
    @Test func heldContentOutlivesItsRemoval() throws {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { list, index in text(list &* 100 &+ RenderNode.ID(index), "Row \(index)") }
        let content = RenderNode("VStack", id: 20, children: [
            text(21, "Content"),
            RenderNode("LazyVStack", id: 22, props: ["revision": 1], count: 2),
        ])
        let presented = RenderNode("Sheet", id: 12, props: ["isPresented": true, "style": "sheet"], children: [text(13, "Anchor"), content])
        let dismissed = RenderNode("Sheet", id: 12, props: ["isPresented": false, "style": "sheet"], children: [text(13, "Anchor")])
        let store = renderer.store
        renderer.apply(presented)
        _ = store.row(22, index: 0)
        store.rowAppeared(22, index: 0)
        store.hold(20)

        renderer.apply(dismissed)
        #expect(store.models[20] == nil, "gone from the tree")
        #expect(store.model(20)?.childIDs == [21, 22], "but still shown")
        #expect(store.model(21)?.node.props["text"] == "Content")
        #expect(store.row(22, index: 0).rootID == 2200, "with its rows")
        #expect(delegate.rowRequests.count == 1, "not fetched again")

        store.release(20)
        #expect(store.model(20) == nil)
        #expect(store.model(21) == nil)
        #expect(store.model(2200) == nil, "its rows go too")

        // Presented again, then removed without a hold: gone at once.
        renderer.apply(presented)
        #expect(store.model(21) != nil)
        renderer.apply(dismissed)
        #expect(store.model(21) == nil)
    }

    @Test func releasingLiveContentKeepsIt() {
        let (renderer, _) = makeRenderer()
        renderer.apply(Self.screen)
        renderer.store.hold(14)
        renderer.store.release(14)
        #expect(renderer.store.model(14) != nil, "still in the tree")
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

    @Test func toolbarPlacements() {
        #expect(Toolbars.placement("primaryAction").name == "primaryAction")
        #expect(Toolbars.placement("cancellationAction").name == "cancellationAction")
        #expect(Toolbars.placement("confirmationAction").name == "confirmationAction")
        #expect(Toolbars.placement("navigation").name == "navigation")
        #expect(Toolbars.placement("principal").name == "principal")
        #expect(Toolbars.placement("someFuturePlacement").name == "automatic")
        #expect(Toolbars.placement(nil).name == "automatic")
        #if os(iOS)
        #expect(Toolbars.placement("bottomBar").name == "bottomBar")
        #else
        #expect(Toolbars.placement("bottomBar").name == "automatic", "macOS has no bottom bar")
        #endif
    }

    @Test func dialogTitleVisibility() {
        #expect(AlertView.visibility("visible") == .visible)
        #expect(AlertView.visibility("hidden") == .hidden)
        #expect(AlertView.visibility("automatic") == .automatic)
        #expect(AlertView.visibility(nil) == .automatic)
    }

    @Test func disclosureAndSearchAreControlValues() throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(RenderNode("Searchable", id: 1, props: ["text": "du", "prompt": "Books"], children: [
            RenderNode("DisclosureGroup", id: 2, props: ["isExpanded": false], children: [text(3, "Details")]),
        ]))
        let search = try #require(renderer.model(1))
        let group = try #require(renderer.model(2))
        #expect(search.value == .string("du"))
        #expect(group.value == .bool(false))
        renderer.store.change(search, to: .string("dun"))
        renderer.store.change(group, to: .bool(true))
        renderer.store.send(1, .submit)
        #expect(delegate.events == [
            .init(node: 1, kind: .change, payload: .string("dun")),
            .init(node: 2, kind: .change, payload: .bool(true)),
            .init(node: 1, kind: .submit, payload: nil),
        ])
        #expect(group.value == .bool(true), "shown before the guest answers")
    }

    @Test func datePickerComponentsAndRanges() {
        #expect(DatePickerNodeView.components("date") == .date)
        #expect(DatePickerNodeView.components("hourAndMinute") == .hourAndMinute)
        #expect(DatePickerNodeView.components("date,hourAndMinute") == [.date, .hourAndMinute])
        #expect(DatePickerNodeView.components("someFuture") == [.date, .hourAndMinute])
        #expect(DatePickerNodeView.components(nil) == [.date, .hourAndMinute])

        let range = DatePickerNodeView.range(["min": 0.0, "max": 60.0])
        #expect(range?.lowerBound.timeIntervalSince1970 == 0)
        #expect(range?.upperBound.timeIntervalSince1970 == 60)
        #expect(DatePickerNodeView.range(["min": 60.0, "max": 0.0]) == nil)
        #expect(DatePickerNodeView.range(["min": 0.0]) == nil)
        #expect(DatePickerNodeView.range(["min": 0.0, "max": .double(.infinity)]) == nil)
    }

    static func refreshable(_ refreshing: Bool) -> RenderNode {
        RenderNode("Refreshable", id: 1, props: ["refreshing": .bool(refreshing)], children: [
            RenderNode("List", id: 2, children: [text(3, "Row")]),
        ])
    }

    @Test func refreshWaitsForTheGuest() async throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.refreshable(false))
        delegate.onEvent = { event in
            if event.kind == .refresh {
                renderer.apply(Self.refreshable(true))
            }
        }
        let model = try #require(renderer.model(1))
        let refresh = Task { await renderer.store.refresh(model) }
        for _ in 0..<100 where delegate.events.isEmpty {
            await Task.yield()
        }
        #expect(delegate.events == [.init(node: 1, kind: .refresh, payload: nil)])
        // Still refreshing: the guest's action hasn't finished.
        renderer.apply(Self.refreshable(false))
        await refresh.value
    }

    @Test func refreshEndsAtOnceWhenTheGuestIsDone() async throws {
        let (renderer, delegate) = makeRenderer()
        renderer.apply(Self.refreshable(false))
        let model = try #require(renderer.model(1))
        await renderer.store.refresh(model)
        #expect(delegate.events.map(\.kind) == [.refresh])
    }

    @Test func glSurfacesComeFromTheProvider() {
        #expect(GLSurfaceViews.provider == nil, "nothing without DarwinGraphics")
        var asked: [Int32] = []
        GLSurfaceViews.provider = { identifier in
            asked.append(identifier)
            return AnyView(EmptyView())
        }
        defer { GLSurfaceViews.provider = nil }
        _ = GLSurfaceViews.view(.int(7))
        _ = GLSurfaceViews.view(nil)
        _ = GLSurfaceViews.view("7")
        _ = GLSurfaceViews.view(.int(Int(Int32.max) + 1))
        #expect(asked == [7])
    }

    @Test func webViewsComeFromTheProvider() {
        #expect(WebViews.provider == nil, "nothing without DarwinWebKit")
        var asked: [Int32] = []
        WebViews.provider = { identifier in
            asked.append(identifier)
            return AnyView(EmptyView())
        }
        defer { WebViews.provider = nil }
        _ = WebViews.view(.int(3))
        _ = WebViews.view(nil)
        _ = WebViews.view("3")
        #expect(asked == [3])
    }

    @Test func videoPlayersComeFromTheProvider() {
        #expect(VideoPlayers.provider == nil, "nothing without DarwinMedia")
        var asked: [String] = []
        VideoPlayers.provider = { identifier, scaling, controls in
            asked.append("\(identifier) \(scaling ?? "-") \(controls ?? "-")")
            return AnyView(EmptyView())
        }
        defer { VideoPlayers.provider = nil }
        _ = VideoPlayers.view(["player": .int(4), "scaling": "fill", "controls": "none"])
        _ = VideoPlayers.view(["player": .int(5)])
        _ = VideoPlayers.view(["scaling": "fit"])
        _ = VideoPlayers.view(["player": "4"])
        #expect(asked == ["4 fill none", "5 - -"])
    }

    @Test func photosComeFromTheProvider() {
        #expect(PhotoViews.provider == nil, "nothing without DarwinPhotos")
        var asked: [String] = []
        PhotoViews.provider = { asset, scaling in
            asked.append("\(asset) \(scaling ?? "-")")
            return AnyView(EmptyView())
        }
        defer { PhotoViews.provider = nil }
        _ = PhotoViews.view(["asset": "A1/L0/001", "scaling": "fit"])
        _ = PhotoViews.view(["asset": "B2"])
        _ = PhotoViews.view(["asset": ""])
        _ = PhotoViews.view(["scaling": "fill"])
        _ = PhotoViews.view(["asset": .int(3)])
        #expect(asked == ["A1/L0/001 fit", "B2 -"])
    }

    @Test func textEditorsComeFromTheProvider() {
        #expect(TextEditorViews.provider == nil, "nothing without DarwinText")
        var asked: [TextEditorNode] = []
        TextEditorViews.provider = { node in
            asked.append(node)
            return AnyView(EmptyView())
        }
        defer { TextEditorViews.provider = nil }
        var reported: [Bool] = []
        let focused = RenderNode("TextEditor", id: 1, props: ["buffer": .int(3), "editable": false, "wraps": false],
                                 modifiers: [ModifierNode("focused", ["value": true])])
        _ = TextEditorViews.view(focused) { reported.append($0) }
        _ = TextEditorViews.view(RenderNode("TextEditor", id: 2, props: ["buffer": .int(4)])) { _ in }
        _ = TextEditorViews.view(RenderNode("TextEditor", id: 3, props: ["buffer": "4"])) { _ in }
        #expect(asked.map(\.buffer) == [3, 4])
        #expect(asked.map(\.isEditable) == [false, true])
        #expect(asked.map(\.wrapsLines) == [false, true])
        #expect(asked.first?.focus?.value == true)
        #expect(asked.last?.focus == nil)
        asked.first?.focus?.report(false)
        #expect(reported == [false])
    }

    @Test func fontsForTextViews() {
        #expect(FontSpec().platformFont == nil, "the body font")
        let sized = FontSpec(style: nil, size: 14, design: "monospaced", weight: nil, italic: nil).platformFont
        #expect(sized?.pointSize == 14)
        #expect(sized?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let bold = FontSpec(style: "headline", size: nil, design: nil, weight: "bold", italic: true).platformFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.italic) == true)
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
