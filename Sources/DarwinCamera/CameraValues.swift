import AVFoundation
import DynamicCamera
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Between AVFoundation's values and the guest's.
enum CameraValues {

    // MARK: Access

    static func access(_ status: AVAuthorizationStatus) -> CameraAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    /// The manifest's `.microphone`, which a video with sound needs.
    static func declaresMicrophone(_ info: [String: Any]) -> Bool {
        (info["RTCapabilities"] as? [String] ?? []).contains("microphone")
    }

    // MARK: Zoom

    /// The device's zoom factor that's the guest's 1: the main lens. A
    /// virtual device with an ultra wide starts at the ultra wide, and
    /// changes to the main lens at its first switch-over factor.
    static func zoomBase(hasUltraWide: Bool, switchOvers: [Double]) -> Double {
        guard hasUltraWide, let first = switchOvers.first, first.isFinite, first >= 1 else { return 1 }
        return first
    }

    /// How far past the main lens the guest may zoom, as the system's
    /// camera does.
    static let maximumZoom = 15.0

    /// The guest's zoom range, from the device's.
    static func zoomRange(minimum: Double, maximum: Double, base: Double) -> ClosedRange<Double> {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, minimum <= maximum, base > 0 else { return 1 ... 1 }
        let lower = minimum / base
        let upper = max(lower, min(maximum / base, maximumZoom))
        return lower ... upper
    }

    /// The device's factor for the guest's, inside what the device can do.
    static func deviceZoom(_ factor: Double, base: Double, minimum: Double, maximum: Double) -> Double {
        min(max(factor * base, minimum), maximum)
    }

    // MARK: Photos

    static func flashMode(_ mode: CameraFlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }

    /// Which way up the device is held, as the picture should be.
    enum Upright: Equatable {
        case portrait, upsideDown, landscapeLeft, landscapeRight

        /// The angle, clockwise, an output turns its frames to stand it
        /// up: a capture connection's `videoRotationAngle`. Landscape left
        /// is the home side on the right, where the sensor is level.
        var rotationAngle: Double {
            switch self {
            case .landscapeLeft: return 0
            case .portrait: return 90
            case .landscapeRight: return 180
            case .upsideDown: return 270
            }
        }

        /// The same, for a system older than `videoRotationAngle`.
        var videoOrientation: AVCaptureVideoOrientation {
            switch self {
            case .landscapeLeft: return .landscapeRight
            case .portrait: return .portrait
            case .landscapeRight: return .landscapeLeft
            case .upsideDown: return .portraitUpsideDown
            }
        }
    }

    /// The upright picture's pixels, from what a JPEG says of itself: an
    /// EXIF orientation from 5 to 8 turns it a quarter.
    static func uprightSize(_ properties: [String: Any]) -> (width: Int, height: Int)? {
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? (height, width) : (width, height)
    }

    /// The upright size of the JPEG at `url`.
    static func uprightSize(ofImageAt url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return uprightSize(properties)
    }

    // MARK: Video

    static let mp4 = "video/mp4"

    static let quickTime = "video/quicktime"

    /// AVFoundation's errors by code: some are only iOS's, and a Mac
    /// may hear of them all the same.
    enum Code {
        static let deviceWasDisconnected = -11808
        static let sessionWasInterrupted = -11818
        static let mediaServicesWereReset = -11819
        static let deviceIsNotAvailableInBackground = -11837
    }

    /// Why a recording ended before it was asked to, from the error a
    /// movie file output finishes with. A file that was finished cleanly
    /// may still come with an error that says so.
    static func recordingInterruption(_ error: (any Error)?) -> CameraError? {
        guard let error = error as NSError? else { return nil }
        switch error.code {
        case AVError.Code.diskFull.rawValue, AVError.Code.outOfMemory.rawValue:
            return .writeFailed
        case Code.sessionWasInterrupted, Code.deviceWasDisconnected, Code.mediaServicesWereReset,
             AVError.Code.deviceNotConnected.rawValue:
            return .interrupted
        case AVError.Code.maximumDurationReached.rawValue, AVError.Code.maximumFileSizeReached.rawValue:
            return nil
        default:
            let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            return finished ? nil : .interrupted
        }
    }

    /// Whether a recording that finished with `error` left a file to keep.
    static func keptFile(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError? else { return true }
        return error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
    }

    /// What the guest is told of a failure to start or to capture.
    static func error(_ error: (any Error)?, otherwise: CameraError = .unknown) -> CameraError {
        guard let error = error as NSError? else { return otherwise }
        if error.domain == NSCocoaErrorDomain {
            return .writeFailed
        }
        guard error.domain == AVFoundationErrorDomain else { return otherwise }
        switch error.code {
        case AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue:
            return .notAuthorized
        case AVError.Code.deviceAlreadyUsedByAnotherSession.rawValue, AVError.Code.deviceInUseByAnotherApplication.rawValue:
            return .busy
        case Code.sessionWasInterrupted, Code.deviceWasDisconnected, Code.mediaServicesWereReset:
            return .interrupted
        case AVError.Code.deviceNotConnected.rawValue, Code.deviceIsNotAvailableInBackground:
            return .unavailable
        case AVError.Code.diskFull.rawValue, AVError.Code.outOfMemory.rawValue:
            return .writeFailed
        default:
            return otherwise
        }
    }

    /// A temporary file for a recording, beside nothing the app owns.
    static func recordingFile(in folder: URL = FileManager.default.temporaryDirectory) -> URL {
        folder.appendingPathComponent("CameraRecording-" + UUID().uuidString).appendingPathExtension("mov")
    }
}
