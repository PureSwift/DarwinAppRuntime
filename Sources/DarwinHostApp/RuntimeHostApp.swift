import DarwinHost
import DarwinUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The SwiftUI app: one window showing the guest's first renderer
/// (`HostRuntime.md` §3, `SwiftUIRenderer.md` §9).
struct RuntimeHostApp: App {

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    #endif

    @ObservedObject private var session = HostSession.shared

    var body: some Scene {
        WindowGroup {
            HostRootView(session: session)
                .onOpenURL { url in
                    DarwinApplication.open(url)
                }
        }
    }
}

/// Starts the guest once the app has finished launching, so it can
/// already open windows and present prompts.
final class LaunchDelegate: NSObject {

    fileprivate func launched() {
        HostSession.shared.start()
    }
}

#if canImport(UIKit)
extension LaunchDelegate: UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launched()
        return true
    }
}
#elseif canImport(AppKit)
extension LaunchDelegate: NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An app launched from its executable (`darwin-app run`) starts as
        // a background process otherwise.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        launched()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

/// The window's content: the guest's renderer once it made one.
///
/// If `rt_main` fails, or the app never makes a renderer, a debug build shows
/// the error, and a release build an empty window (`HostRuntime.md` §4).
struct HostRootView: View {

    @ObservedObject var session: HostSession

    var body: some View {
        if let renderer = session.renderer {
            RendererView(renderer: renderer)
        } else {
            switch session.state {
            case .starting:
                Color.clear
            case .running:
                // The app runs without a UI, such as ExampleApp.
                Color.clear
            case .failed(let message):
                #if DEBUG
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .padding()
                #else
                let _ = message
                Color.clear
                #endif
            }
        }
    }
}
