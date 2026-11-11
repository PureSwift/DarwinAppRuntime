import AVFoundation
import DynamicRuntime
import Foundation
import UserNotifications

/// Permission providers for capabilities no contract module owns.
enum SystemPermissions {

    static func providers() -> [Capability: any PermissionProvider] {
        [
            .network: GrantedPermission(),
            .graphics: GrantedPermission(),
            .camera: CameraPermission(),
            .notifications: NotificationPermission(),
        ]
    }
}

/// `AVCaptureDevice`'s video authorization.
final class CameraPermission: PermissionProvider {

    func status() -> PermissionStatus {
        PermissionStatus(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            completion(status())
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                completion(self.status())
            }
        }
    }
}

/// `UNUserNotificationCenter`'s authorization. Its settings arrive
/// asynchronously, so `status` reports the last ones read: they're read when
/// the provider is made and after every request.
final class NotificationPermission: PermissionProvider {

    private var last: PermissionStatus = .notDetermined

    private var center: UNUserNotificationCenter? {
        // Only an app has a notification center: elsewhere, such as in a
        // test runner, `current()` raises an exception.
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    init() {
        refresh { _ in }
    }

    func status() -> PermissionStatus {
        last
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        guard let center else {
            completion(.unavailable)
            return
        }
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            self.refresh(completion)
        }
    }

    private func refresh(_ completion: @escaping (PermissionStatus) -> Void) {
        guard let center else {
            last = .unavailable
            completion(last)
            return
        }
        center.getNotificationSettings { settings in
            let status = PermissionStatus(settings.authorizationStatus)
            DispatchQueue.main.async {
                self.last = status
                completion(status)
            }
        }
    }
}

extension PermissionStatus {

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .granted
        @unknown default: self = .denied
        }
    }

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .granted
        case .provisional: self = .limited
        #if os(iOS)
        case .ephemeral: self = .limited
        #endif
        @unknown default: self = .denied
        }
    }
}
