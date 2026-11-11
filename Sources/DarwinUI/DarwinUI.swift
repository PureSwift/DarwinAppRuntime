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

    /// Identifies this renderer's scene in `RendererScenes`.
    let sceneID = UUID()

    init(delegate: any RendererDelegate) {
        self.store = RenderStore(delegate: delegate)
    }

    deinit {
        // The guest released it.
        let id = sceneID
        if Thread.isMainThread {
            RendererScenes.shared.remove(id)
        } else {
            DispatchQueue.main.async { RendererScenes.shared.remove(id) }
        }
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

/// What a renderer shows: its store, without the renderer itself, so a
/// window doesn't keep a renderer the guest released.
public struct RendererScene: Identifiable {

    public let id: UUID

    let store: RenderStore
}

/// Every live renderer's scene, in the order the guest made them. The host
/// app's window shows the first one; it observes this to learn when the
/// guest made it.
///
/// Renderers aren't kept alive here: when the guest releases one, its scene
/// leaves, and so does the guest's delegate once no view shows it.
public final class RendererScenes: ObservableObject {

    public static let shared = RendererScenes()

    @Published public private(set) var scenes: [RendererScene] = []

    private init() { }

    func add(_ renderer: SwiftUIRenderer) {
        scenes.append(RendererScene(id: renderer.sceneID, store: renderer.store))
    }

    func remove(_ id: UUID) {
        scenes.removeAll { $0.id == id }
    }
}

/// A renderer's root view, which the host app puts in its window: the
/// guest's last applied tree, or nothing before the first.
public struct RendererView: View {

    @ObservedObject private var store: RenderStore

    public init(scene: RendererScene) {
        self.store = scene.store
    }

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
