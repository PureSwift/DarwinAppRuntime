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
        let before = RendererScenes.shared.renderers.count
        let renderer = SwiftUIRenderer.make(RecordingDelegate())
        #expect(RendererScenes.shared.renderers.count == before + 1)
        #expect(RendererScenes.shared.renderers.last === renderer)
    }
}
