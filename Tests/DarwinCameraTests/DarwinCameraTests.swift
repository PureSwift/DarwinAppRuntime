import AVFoundation
import DynamicCamera
import DynamicRuntime
import Foundation
import ImageIO
import RuntimeCamera
import Testing
import UniformTypeIdentifiers
@testable import DarwinCamera

/// Between AVFoundation's values and the guest's. Nothing here opens a
/// camera, or asks the user for one.
@Suite("Camera values")
struct CameraValueTests {

    @Test func readsTheUsersLeave() {
        #expect(CameraValues.access(.notDetermined) == .notDetermined)
        #expect(CameraValues.access(.restricted) == .restricted)
        #expect(CameraValues.access(.denied) == .denied)
        #expect(CameraValues.access(.authorized) == .authorized)
    }

    @Test func readsWhetherTheManifestDeclaresTheMicrophone() {
        #expect(!CameraValues.declaresMicrophone([:]))
        #expect(!CameraValues.declaresMicrophone(["RTCapabilities": ["camera"]]))
        #expect(CameraValues.declaresMicrophone(["RTCapabilities": ["camera", "microphone"]]))
    }

    @Test func makesTheMainLensOne() {
        // A triple camera: the ultra wide at the device's 1, the main
        // lens at 2 and the telephoto at 6.
        #expect(CameraValues.zoomBase(hasUltraWide: true, switchOvers: [2, 6]) == 2)
        // A dual camera starts at the main lens.
        #expect(CameraValues.zoomBase(hasUltraWide: false, switchOvers: [2]) == 1)
        #expect(CameraValues.zoomBase(hasUltraWide: false, switchOvers: []) == 1)
        #expect(CameraValues.zoomBase(hasUltraWide: true, switchOvers: []) == 1)
        #expect(CameraValues.zoomBase(hasUltraWide: true, switchOvers: [.nan]) == 1)
    }

    @Test func givesTheGuestItsZoomRange() {
        #expect(CameraValues.zoomRange(minimum: 1, maximum: 123, base: 2) == 0.5 ... 15)
        #expect(CameraValues.zoomRange(minimum: 1, maximum: 10, base: 1) == 1 ... 10)
        #expect(CameraValues.zoomRange(minimum: 1, maximum: 1, base: 1) == 1 ... 1)
        #expect(CameraValues.zoomRange(minimum: 2, maximum: 1, base: 1) == 1 ... 1)
        #expect(CameraValues.zoomRange(minimum: 0, maximum: 4, base: 1) == 1 ... 1)
        #expect(CameraValues.deviceZoom(0.5, base: 2, minimum: 1, maximum: 123) == 1)
        #expect(CameraValues.deviceZoom(3, base: 2, minimum: 1, maximum: 123) == 6)
        #expect(CameraValues.deviceZoom(100, base: 2, minimum: 1, maximum: 123) == 123)
    }

    @Test func usesTheFlashAsTold() {
        #expect(CameraValues.flashMode(.off) == .off)
        #expect(CameraValues.flashMode(.on) == .on)
        #expect(CameraValues.flashMode(.auto) == .auto)
    }

    @Test func turnsCapturesUpright() {
        #expect(CameraValues.Upright.landscapeLeft.rotationAngle == 0)
        #expect(CameraValues.Upright.portrait.rotationAngle == 90)
        #expect(CameraValues.Upright.landscapeRight.rotationAngle == 180)
        #expect(CameraValues.Upright.upsideDown.rotationAngle == 270)
        // The output's orientation is named for the picture, not the device.
        #expect(CameraValues.Upright.landscapeLeft.videoOrientation == .landscapeRight)
        #expect(CameraValues.Upright.portrait.videoOrientation == .portrait)
        #expect(CameraValues.Upright.landscapeRight.videoOrientation == .landscapeLeft)
        #expect(CameraValues.Upright.upsideDown.videoOrientation == .portraitUpsideDown)
    }

    @Test func measuresThePhotoUpright() throws {
        func properties(_ orientation: Int?) -> [String: Any] {
            var properties: [String: Any] = [kCGImagePropertyPixelWidth as String: 4032, kCGImagePropertyPixelHeight as String: 3024]
            properties[kCGImagePropertyOrientation as String] = orientation
            return properties
        }
        #expect(CameraValues.uprightSize(properties(nil))! == (4032, 3024))
        #expect(CameraValues.uprightSize(properties(1))! == (4032, 3024))
        #expect(CameraValues.uprightSize(properties(3))! == (4032, 3024))
        #expect(CameraValues.uprightSize(properties(6))! == (3024, 4032))
        #expect(CameraValues.uprightSize(properties(8))! == (3024, 4032))
        #expect(CameraValues.uprightSize([:]) == nil)

        // A JPEG held in portrait: its pixels lie on their side, and say so.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DarwinCameraTests-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(CameraValues.uprightSize(ofImageAt: url)! == (30, 40))
        #expect(CameraValues.uprightSize(ofImageAt: url.appendingPathExtension("missing")) == nil)
    }

    @Test func saysWhatCutARecordingShort() {
        func error(_ code: Int, finished: Bool? = nil) -> NSError {
            var info: [String: Any] = [:]
            info[AVErrorRecordingSuccessfullyFinishedKey] = finished
            return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
        }
        func error(_ code: AVError.Code, finished: Bool? = nil) -> NSError {
            error(code.rawValue, finished: finished)
        }
        #expect(CameraValues.recordingInterruption(nil) == nil)
        #expect(CameraValues.recordingInterruption(error(.diskFull, finished: true)) == .writeFailed)
        #expect(CameraValues.recordingInterruption(error(CameraValues.Code.sessionWasInterrupted, finished: true)) == .interrupted)
        #expect(CameraValues.recordingInterruption(error(CameraValues.Code.deviceWasDisconnected, finished: true)) == .interrupted)
        #expect(CameraValues.recordingInterruption(error(.maximumDurationReached, finished: true)) == nil)
        #expect(CameraValues.recordingInterruption(error(.unknown, finished: true)) == nil)
        #expect(CameraValues.recordingInterruption(error(.unknown, finished: false)) == .interrupted)
        // Whether there's a file to keep.
        #expect(CameraValues.keptFile(nil))
        #expect(CameraValues.keptFile(error(CameraValues.Code.sessionWasInterrupted, finished: true)))
        #expect(!CameraValues.keptFile(error(CameraValues.Code.sessionWasInterrupted, finished: false)))
        #expect(!CameraValues.keptFile(error(.unknown)))
    }

    @Test func saysWhyACaptureFailed() {
        func error(_ code: Int) -> NSError {
            NSError(domain: AVFoundationErrorDomain, code: code)
        }
        func error(_ code: AVError.Code) -> NSError {
            error(code.rawValue)
        }
        #expect(CameraValues.error(error(.applicationIsNotAuthorizedToUseDevice)) == .notAuthorized)
        #expect(CameraValues.error(error(.deviceAlreadyUsedByAnotherSession)) == .busy)
        #expect(CameraValues.error(error(CameraValues.Code.sessionWasInterrupted)) == .interrupted)
        #expect(CameraValues.error(error(.deviceNotConnected)) == .unavailable)
        #expect(CameraValues.error(error(.diskFull)) == .writeFailed)
        #expect(CameraValues.error(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) == .writeFailed)
        #expect(CameraValues.error(error(.unknown), otherwise: .unavailable) == .unavailable)
        #expect(CameraValues.error(NSError(domain: "elsewhere", code: 1)) == .unknown)
        #expect(CameraValues.error(nil, otherwise: .busy) == .busy)
    }

    @Test func recordsBesideNothingTheAppOwns() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let first = CameraValues.recordingFile(in: folder), second = CameraValues.recordingFile(in: folder)
        #expect(first.deletingLastPathComponent().path == "/tmp/x")
        #expect(first.pathExtension == "mov")
        #expect(first.lastPathComponent.hasPrefix("CameraRecording-"))
        #expect(first != second)
    }
}

/// The module as the host registers it. It changes `HostCameraCapture`'s
/// settings, so it runs alone.
@Suite("Camera module", .serialized)
struct CameraModuleTests {

    @Test func reportsTheCameraAndTheMicrophone() {
        let providers = DarwinCamera.permissionProviders()
        #expect(Set(providers.keys) == [.camera, .microphone])
        #expect(DarwinCamera.contracts.map(\.name).contains("org.pureswift.camera.Capture"))
    }

    @Test func hasNoCameraWithoutAPlatform() {
        HostCameraCapture.reset()
        defer { HostCameraCapture.reset() }
        let providers = DarwinCamera.permissionProviders()
        #expect(providers[.camera]?.status() == .unavailable)
        #expect(providers[.microphone]?.status() == .unavailable)
        var answered: PermissionStatus?
        providers[.camera]?.request { answered = $0 }
        #expect(answered == .unavailable)
    }
}
