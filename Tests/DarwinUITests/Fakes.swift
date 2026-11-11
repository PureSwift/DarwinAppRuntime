import DynamicRuntime
import DynamicUI
@testable import DarwinUI

/// A guest stand-in: records events and row requests, and answers them
/// through `onEvent` and `rows`, as a guest answers with an update before
/// the call returns.
final class RecordingDelegate: RendererDelegate {

    struct Event: Equatable {
        var node: RenderNode.ID
        var kind: RenderEventKind
        var payload: PropValue?
    }

    var events: [Event] = []

    var rowRequests: [(list: RenderNode.ID, index: Int)] = []

    /// Called for each event, after it's recorded.
    var onEvent: (Event) -> Void = { _ in }

    /// Row `index` of a list, or `nil` for none.
    var rows: (RenderNode.ID, Int) -> RenderNode? = { _, _ in nil }

    func event(_ node: [UInt8], kind: Int32, payload: [UInt8]) {
        let event = Event(
            node: try! RenderCodec.decode(id: node),
            kind: RenderEventKind(rawValue: kind)!,
            payload: payload.isEmpty ? nil : try! RenderCodec.decode(payload: payload)
        )
        events.append(event)
        onEvent(event)
    }

    func rowCount(_ list: [UInt8]) -> Int32 {
        0
    }

    func row(_ list: [UInt8], index: Int32) -> [UInt8] {
        let list = try! RenderCodec.decode(id: list)
        rowRequests.append((list, Int(index)))
        return rows(list, Int(index)).map(RenderCodec.encode) ?? []
    }
}

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [(descriptor: ContractDescriptor, hasStatics: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        // A switch, not `!= nil`: comparing needs the typed-throws function
        // type's metadata, which needs macOS 15 at run time.
        switch statics {
        case .some: registered.append((descriptor, true))
        case .none: registered.append((descriptor, false))
        }
    }
}

/// A renderer over a recording delegate, whose stale rows refresh only when
/// a test says so.
func makeRenderer(_ delegate: RecordingDelegate = RecordingDelegate()) -> (SwiftUIRenderer, RecordingDelegate) {
    let renderer = SwiftUIRenderer(delegate: delegate)
    renderer.store.schedule = { _ in }
    return (renderer, delegate)
}

extension SwiftUIRenderer {

    func apply(_ tree: RenderNode) {
        apply(RenderCodec.encode(tree))
    }

    func replace(_ id: RenderNode.ID, with tree: RenderNode) {
        replaceSubtree(RenderCodec.encode(id: id), tree: RenderCodec.encode(tree))
    }

    func model(_ id: RenderNode.ID) -> NodeModel? {
        store.model(id)
    }
}

func text(_ id: RenderNode.ID, _ string: String) -> RenderNode {
    RenderNode("Text", id: id, props: ["text": .string(string)])
}
