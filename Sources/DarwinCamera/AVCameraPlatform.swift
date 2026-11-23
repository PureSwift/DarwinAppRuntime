import AVFoundation
import DynamicCamera
import Foundation
import RuntimeCamera

/// The device's cameras and the user's leave for them and the microphone,
/// through AVFoundation: the `CameraPlatform` behind `HostCameraCapture`.
final class AVCameraPlatform: CameraPlatform {

    var positions: [CameraPosition] {
        [CameraPosition.back, .front, .external].filter { Self.device(for: $0) != nil }
    }

    var access: CameraAccess {
        CameraValues.access(AVCaptureDevice.authorizationStatus(for: .video))
    }

    var microphoneAccess: CameraAccess {
        CameraValues.access(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestAccess(_ completion: @escaping (CameraAccess) -> Void) {
        request(.video, completion)
    }

    func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void) {
        request(.audio, completion)
    }

    private func request(_ media: AVMediaType, _ completion: @escaping (CameraAccess) -> Void) {
        AVCaptureDevice.requestAccess(for: media) { _ in
            // On a queue of AVFoundation's.
            DispatchQueue.main.async {
                completion(CameraValues.access(AVCaptureDevice.authorizationStatus(for: media)))
            }
        }
    }

    func makeEngine(for camera: HostCameraCapture) -> any CameraEngine {
        AVCameraEngine(camera: camera)
    }

    // MARK: Devices

    /// The camera at a position: on a phone the widest virtual device
    /// there, whose zoom changes lens by itself.
    static func device(for position: CameraPosition) -> AVCaptureDevice? {
        let (types, place) = kinds(for: position)
        guard !types.isEmpty else { return nil }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: place)
        // In the order asked for: the discovery session sorts its own way.
        for type in types {
            if let device = session.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return nil
    }

    /// The kinds of device that are each position's, widest first.
    private static func kinds(for position: CameraPosition) -> ([AVCaptureDevice.DeviceType], AVCaptureDevice.Position) {
        #if os(iOS)
        switch position {
        case .back:
            return ([.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera], .back)
        case .front:
            return ([.builtInTrueDepthCamera, .builtInWideAngleCamera], .front)
        case .external:
            if #available(iOS 17, *) {
                return ([.external], .unspecified)
            }
            return ([], .unspecified)
        }
        #else
        // A Mac's own camera faces the user. Any other is external: one
        // plugged in, a display's, or an iPhone's through Continuity.
        switch position {
        case .back:
            return ([], .unspecified)
        case .front:
            return ([.builtInWideAngleCamera], .unspecified)
        case .external:
            if #available(macOS 14, *) {
                return ([.external, .continuityCamera], .unspecified)
            }
            return ([.externalUnknown], .unspecified)
        }
        #endif
    }

    static var microphone: AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }
}
