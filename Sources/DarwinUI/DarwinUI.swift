import Combine
import DarwinHost
import DynamicRuntime
import DynamicUI
import SwiftUI

/// The SwiftUI renderer module (`SwiftUIRenderer.md`): registers
/// `SwiftUIRenderer` for the `Renderer` contract, and the
/// `RendererDelegate` callback interface.
public enum DarwinUI: HostModule {

    public static var contracts: [ContractDescriptor] {
        [RendererProxy.descriptor, RendererDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        RendererProxy.register(SwiftUIRenderer.self, in: registrar)
        RendererDelegateProxy.registerInterface(in: registrar)
    }
}

/// The `Renderer` contract implementation (§9.3): decodes the guest's trees
/// into a `RenderStore`, which `RendererView` draws.
///
/// `make` is called by the guest, on the main thread, normally during
/// `rt_main`. Every call is on the main thread.
public final class SwiftUIRenderer: Renderer {

    let store: RenderStore

    init(delegate: any RendererDelegate) {
        self.store = RenderStore(delegate: delegate)
    }

    /// Makes a renderer and adds it to `RendererScenes.shared`.
    public static func make(_ delegate: any RendererDelegate) -> SwiftUIRenderer {
        let renderer = SwiftUIRenderer(delegate: delegate)
        RendererScenes.shared.add(renderer)
        return renderer
    }

    public func apply(_ tree: [UInt8]) {
        do {
            store.apply(try RenderCodec.decode(tree))
        } catch {
            AppHost.logger.error("apply: \(String(describing: error), privacy: .public)")
        }
    }

    public func replaceSubtree(_ id: [UInt8], tree: [UInt8]) {
        do {
            let id = try RenderCodec.decode(id: id)
            store.replaceSubtree(id, with: try RenderCodec.decode(tree))
        } catch {
            AppHost.logger.error("replaceSubtree: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Every live renderer, in the order the guest made them. The host app's
/// window shows the first one's view; it observes this to learn when the
/// guest made it.
public final class RendererScenes: ObservableObject {

    public static let shared = RendererScenes()

    @Published public private(set) var renderers: [SwiftUIRenderer] = []

    private init() { }

    func add(_ renderer: SwiftUIRenderer) {
        renderers.append(renderer)
    }
}

/// A renderer's root view, which the host app puts in its window: the
/// guest's last applied tree, or nothing before the first.
public struct RendererView: View {

    @ObservedObject private var store: RenderStore

    public init(renderer: SwiftUIRenderer) {
        self.store = renderer.store
    }

    public var body: some View {
        if let id = store.rootID, let model = store.model(id) {
            NodeView(model: model, store: store)
                .id(id)
        }
    }
}
