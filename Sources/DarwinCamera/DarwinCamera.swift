import DarwinFiles
import DarwinHost
import DarwinUI
import DynamicCamera
import DynamicRuntime
import Foundation
import RuntimeCamera
import RuntimeNative
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The camera contract (`HostRuntime.md` §5.16): `CameraCapture` and its
/// delegate.
///
/// The contract is AppRuntime's `HostCameraCapture`, which finds each
/// file through `HostFiles`, keeps one camera on and one capture at a
/// time, answers each request once, refuses sound without the manifest's
/// `.microphone`, clamps the zoom, and turns the camera off for the
/// background. This module gives it AVFoundation's cameras
/// (`AVCameraPlatform`, `AVCameraEngine`) and the app's comings and goings.
///
/// Registering it also gives the SwiftUI renderer its `CameraPreview`
/// views.
public enum DarwinCamera: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostCameraModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // A capture is written where `HostFiles` finds it, whether or not
        // the app uses `Files` itself.
        DarwinFiles.configureIfNeeded()
        HostCameraCapture.platform = platform
        HostCameraCapture.allowsMicrophone = CameraValues.declaresMicrophone(Bundle.main.infoDictionary ?? [:])
        // The guest's `Clock`, so the time a recording began is on its
        // timeline.
        HostCameraCapture.clock = (registrar as? NativeRuntime)?.runtime.clock ?? DispatchClock()
        HostCameraModule.register(in: registrar)
        CameraPreviews.provider = { identifier, scaling in
            AnyView(CameraPreviewView(identifier: identifier, fill: scaling != CameraScaling.fit.rawValue))
        }
        observe()
    }

    /// The camera's and the microphone's, which replace the host's own
    /// camera permission.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.camera: CapturePermission(microphone: false), .microphone: CapturePermission(microphone: true)]
    }

    nonisolated(unsafe) static let platform = AVCameraPlatform()

    nonisolated(unsafe) private static var observing = false

    /// The camera is on only while the app is in front. A Mac app isn't
    /// sent to the background: its camera goes off while it's hidden.
    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        #if canImport(UIKit)
        // Which way the device is held, for the pictures to stand upright.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let away = UIApplication.didEnterBackgroundNotification
        let back = UIApplication.willEnterForegroundNotification
        #else
        let away = NSApplication.didHideNotification
        let back = NSApplication.didUnhideNotification
        #endif
        center.addObserver(forName: away, object: nil, queue: .main) { _ in
            HostCameraCapture.applicationDidEnterBackground()
        }
        center.addObserver(forName: back, object: nil, queue: .main) { _ in
            HostCameraCapture.applicationWillEnterForeground()
        }
    }
}

/// Camera and microphone access as the built-in `Permissions` contract
/// reports it: AppRuntime's `CameraPermission`, for this host's protocol.
final class CapturePermission: DarwinHost.PermissionProvider {

    private let permission: CameraPermission

    init(microphone: Bool) {
        permission = CameraPermission(microphone: microphone)
    }

    func status() -> PermissionStatus {
        permission.status()
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        permission.request(completion)
    }
}
