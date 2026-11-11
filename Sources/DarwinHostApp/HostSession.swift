import Combine
import DarwinHost
import DarwinUI
import Foundation

/// The running app: starts the guest once the app has launched, and tells
/// the window what to show.
final class HostSession: ObservableObject {

    enum State: Equatable {

        /// Before launch, or while `rt_main` runs.
        case starting

        /// `rt_main` returned `.ok`.
        case running

        /// The app can't run on this host, or `rt_main` failed.
        case failed(String)
    }

    static let shared = HostSession()

    /// The app library's exports, set by `HostApp.run`.
    var entry: AppEntryPoints?

    @Published private(set) var state = State.starting

    /// What the window shows: the first renderer the guest made and still
    /// holds.
    @Published private(set) var scene: RendererScene?

    private(set) var host: AppHost?

    private var scenes: AnyCancellable?

    init() {
        scenes = RendererScenes.shared.$scenes
            .map(\.first)
            .sink { [weak self] scene in
                self?.scene = scene
            }
    }

    /// `HostRuntime.md` §4, steps 1–6. Called once, on the main thread,
    /// after the app finished launching.
    func start(info: () throws -> AppInfo = { try AppInfo.main() }) {
        guard host == nil else { return }
        guard let entry else {
            fail("No app library: start the app with HostApp.run(_:)")
            return
        }
        do {
            let host = AppHost(info: try info(), modules: HostApp.modules)
            try host.prepare()
            self.host = host
            let status = host.start(entry)
            if status == .ok {
                state = .running
            } else {
                fail("The app's rt_main failed: \(status)")
            }
        } catch {
            fail("\(error)")
        }
    }

    private func fail(_ message: String) {
        AppHost.logger.error("\(message, privacy: .public)")
        state = .failed(message)
    }
}
