#if canImport(AppKit)
import AppKit
import DynamicUI
import SwiftUI
import Testing
@testable import DarwinUI

/// Hosts `RendererView` in an `NSHostingView` and lays it out, for every
/// node type and modifier kind.
@MainActor
@Suite("Rendering", .serialized)
struct RenderingTests {

    static let modifiers: [ModifierNode] = [
        ModifierNode("padding", ["top": 1.0, "leading": 2.0, "bottom": 3.0, "trailing": 4.0]),
        ModifierNode("frame", ["width": 100.0, "height": 40.0, "horizontal": "leading", "vertical": "top"]),
        ModifierNode("frame", ["minWidth": 10.0, "maxWidth": .double(.infinity), "maxHeight": 200.0, "horizontal": "center", "vertical": "center"]),
        ModifierNode("frame", ["width": .double(.infinity), "height": -1.0]),
        ModifierNode("offset", ["x": 1.0, "y": 2.0]),
        ModifierNode("background", ["color": "red"]),
        ModifierNode("background", ["color": .array(["blue", 0.5])]),
        ModifierNode("background", ["color": .int(0x80FF_8000)]),
        ModifierNode("foregroundColor", ["color": "mint"]),
        ModifierNode("foregroundColor"),
        ModifierNode("tint", ["color": "cyan"]),
        ModifierNode("tint"),
        ModifierNode("opacity", ["value": 0.5]),
        ModifierNode("cornerRadius", ["radius": 4.0]),
        ModifierNode("border", ["color": "brown", "width": 2.0]),
        ModifierNode("shadow", ["color": .int(0x5400_0000), "radius": 3.0, "x": 0.0, "y": 1.0]),
        ModifierNode("font", ["style": "headline"]),
        ModifierNode("font", ["size": 13.0, "weight": "semibold", "design": "rounded", "italic": true]),
        ModifierNode("font", ["style": "caption", "design": "monospaced"]),
        ModifierNode("font"),
        ModifierNode("fontWeight", ["weight": "bold"]),
        ModifierNode("fontWeight"),
        ModifierNode("italic", ["value": true]),
        ModifierNode("lineLimit", ["lines": 2]),
        ModifierNode("lineLimit"),
        ModifierNode("multilineTextAlignment", ["alignment": "center"]),
        ModifierNode("disabled", ["value": false]),
        ModifierNode("onTapGesture", ["count": 2]),
        ModifierNode("accessibilityLabel", ["text": "Label"]),
        ModifierNode("accessibilityIdentifier", ["identifier": "identifier"]),
        ModifierNode("someFutureModifier", ["value": 1]),
    ]

    /// One node of every type, each with every modifier kind.
    static var everything: RenderNode {
        var next: RenderNode.ID = 1000
        func node(_ type: String, _ props: [String: PropValue] = [:], _ children: [RenderNode] = [], count: Int? = nil) -> RenderNode {
            next += 1
            return RenderNode(type, id: next, props: props, modifiers: modifiers, children: children, count: count)
        }
        func label(_ string: String) -> RenderNode {
            node("Text", ["text": .string(string)])
        }
        let content: [RenderNode] = [
            label("Text"),
            node("Image", ["systemName": "star", "resizable": true]),
            node("Image", ["name": "missing"]),
            node("Image"),
            node("Label", ["title": "Label", "systemImage": "star"]),
            node("Spacer", ["minLength": 8.0]),
            node("Divider"),
            node("Color", ["color": "indigo"]),
            node("Color", ["color": "notAColor"]),
            node("HStack", ["alignment": "top", "spacing": 4.0], [label("a"), label("b")]),
            node("ZStack", ["horizontal": "trailing", "vertical": "bottom"], [label("back"), label("front")]),
            node("ScrollView", ["axes": "both", "showsIndicators": false], [label("scrolled")]),
            node("Button", [:], [label("Button")]),
            node("NavigationLink", [:], [label("Link")]),
            node("Toggle", ["isOn": true], [label("Toggle")]),
            node("TextField", ["text": "text", "placeholder": "Name"]),
            node("TextField", ["text": "secret", "placeholder": "Password", "secure": true]),
            node("Slider", ["value": 0.5, "min": 0.0, "max": 1.0]),
            node("Slider", ["value": 2.0, "min": 0.0, "max": 10.0, "step": 1.0]),
            node("Slider", ["value": 0.0, "min": 1.0, "max": 0.0, "step": 0.0]),
            node("Stepper", ["value": 1, "min": .int(.min), "max": .int(.max), "step": 1], [label("Stepper")]),
            node("ProgressView", ["total": 1.0, "value": 0.25, "title": "Loading"]),
            node("ProgressView", ["total": 0.0, "value": 5.0]),
            node("ProgressView", ["total": 1.0]),
            node("List", [:], [
                node("Section", ["header": "Header", "footer": "Footer"], [label("Row"), node("NavigationLink", [:], [label("Row link")])]),
                node("Section", [:], [label("Row")]),
            ]),
            node("List", ["revision": 1], count: 3),
            node("LazyVStack", ["alignment": "leading", "spacing": 2.0, "revision": 1], count: 2),
            node("LazyHStack", ["alignment": "bottom", "spacing": 2.0, "revision": 1], count: 2),
            node("LazyVStack", ["alignment": "trailing", "spacing": 2.0], [label("eager")]),
            node("LazyHStack", ["alignment": "top", "spacing": 2.0], [label("eager")]),
            node("NavLevel", ["title": "Loose level"], [label("level")]),
            node("SomeFutureView", ["value": 1], [label("never shown")]),
        ]
        let root = node("NavLevel", ["title": "Root"], [node("VStack", ["alignment": "leading", "spacing": 8.0], content)])
        let detail = node("NavLevel", ["title": "Detail"], [label("Detail")])
        return RenderNode("NavStack", id: 1, children: [root, detail])
    }

    static func host(_ renderer: SwiftUIRenderer) -> NSHostingView<RendererView> {
        let view = NSHostingView(rootView: RendererView(renderer: renderer))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 2000)
        return view
    }

    static func layOut(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }

    @Test func everyNodeAndModifierLaysOut() throws {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { list, index in
            RenderNode("Text", id: list &* 100 &+ RenderNode.ID(index), props: ["text": .string("Row \(index)")], modifiers: Self.modifiers)
        }
        let view = Self.host(renderer)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        Self.layOut(view)
        renderer.apply(Self.everything)
        Self.layOut(view)
        #expect(view.fittingSize.width >= 0)
        #expect(!delegate.rowRequests.isEmpty, "drew the root level's lazy containers")
        #expect(UnknownTypes.logged.contains("SomeFutureView"))

        // An update, then a pop, then a new tree.
        renderer.store.schedule = { $0() }
        var updated = Self.everything
        updated.children[1].props["title"] = "Detail 2"
        renderer.apply(updated)
        Self.layOut(view)
        renderer.store.pop(try #require(renderer.model(1)), to: 1)
        Self.layOut(view)
        renderer.apply(text(5, "Done"))
        Self.layOut(view)
        #expect(renderer.store.models.count == 1)
    }

    @Test func lazyListFetchesRowsItShows() {
        let (renderer, delegate) = makeRenderer()
        delegate.rows = { _, index in RenderStoreTests.fruitRow(index) }
        let view = Self.host(renderer)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        renderer.apply(RenderNode("LazyVStack", id: 10, props: ["alignment": "leading", "spacing": 8.0, "revision": 1], count: 3))
        Self.layOut(view)
        // Each row on screen once; SwiftUI decides how many that is.
        let requested = delegate.rowRequests.map(\.index)
        #expect(!requested.isEmpty)
        #expect(Set(requested).count == requested.count)
        #expect(requested.allSatisfy { (0..<3).contains($0) })
        for index in requested {
            #expect(renderer.model(RenderNode.ID(100 + index * 10)) != nil)
        }
    }

    @Test func emptyRendererShowsNothing() {
        let (renderer, _) = makeRenderer()
        let view = Self.host(renderer)
        Self.layOut(view)
        #expect(renderer.store.rootID == nil)
    }
}
#endif
