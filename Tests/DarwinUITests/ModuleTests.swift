import DynamicUI
import Testing
@testable import DarwinUI

@MainActor
@Suite("DarwinUI module", .serialized)
struct ModuleTests {

    @Test func registersTheRendererAndItsDelegate() {
        let registrar = RecordingRegistrar()
        DarwinUI.register(in: registrar)
        #expect(registrar.registered.map(\.descriptor.name) == ["org.pureswift.ui.Renderer", "org.pureswift.ui.RendererDelegate"])
        #expect(registrar.registered.map(\.hasStatics) == [true, false])
        #expect(registrar.registered.map(\.descriptor) == DarwinUI.contracts)
        #expect(DarwinUI.isUsed(by: ["org.pureswift.ui.Renderer"]))
        #expect(!DarwinUI.isUsed(by: ["org.pureswift.bluetooth.Central"]))
    }

    @Test func makeAddsTheRendererToTheScenes() {
        let before = RendererScenes.shared.scenes.count
        let renderer = SwiftUIRenderer.make(RecordingDelegate())
        #expect(RendererScenes.shared.scenes.count == before + 1)
        #expect(RendererScenes.shared.scenes.last?.id == renderer.sceneID)
        #expect(RendererScenes.shared.scenes.last?.store === renderer.store)
    }

    @Test func releasingTheRendererRemovesItsScene() {
        let before = RendererScenes.shared.scenes.map(\.id)
        weak var released: SwiftUIRenderer?
        do {
            let renderer = SwiftUIRenderer.make(RecordingDelegate())
            released = renderer
            #expect(RendererScenes.shared.scenes.map(\.id) == before + [renderer.sceneID])
        }
        #expect(released == nil)
        #expect(RendererScenes.shared.scenes.map(\.id) == before)
    }

    @Test func aSceneDoesNotKeepItsRendererAlive() {
        weak var released: SwiftUIRenderer?
        var scene: RendererScene?
        do {
            let renderer = SwiftUIRenderer.make(RecordingDelegate())
            released = renderer
            scene = RendererScenes.shared.scenes.last
        }
        #expect(scene != nil)
        #expect(released == nil)
    }
}
