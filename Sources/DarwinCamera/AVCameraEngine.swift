import AVFoundation
import DynamicCamera
import Foundation
import RuntimeCamera
#if canImport(UIKit)
import UIKit
#endif

/// One camera: an `AVCaptureSession` with the position's device, a photo
/// output, and a movie file output while a recording is under way.
///
/// The `CameraEngine` calls come on the main thread, and the session is
/// configured, started and stopped on a queue of its own, as AVFoundation
/// asks. What happens is reported to the `HostCameraCapture` on the main
/// thread. `generation` tells a report from a start that's been stopped
/// or replaced since, which is dropped.
final class AVCameraEngine: NSObject, CameraEngine {

    private weak var camera: HostCameraCapture?

    /// What a `CameraPreview` node shows.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "org.pureswift.camera.session")

    private let photoOutput = AVCapturePhotoOutput()

    private let movieOutput = AVCaptureMovieFileOutput()

    // MARK: Main thread

    private var generation = 0

    /// Whether the camera has been asked to be on.
    private var isOn = false

    /// Whether the system's taking the camera has been reported.
    private var isInterrupted = false

    /// The guest's zoom, and what it may be.
    private(set) var zoomFactor = 1.0

    private var zoomRange: ClosedRange<Double> = 1 ... 1

    private var hasFlash = false

    private var flashMode = AVCaptureDevice.FlashMode.off

    /// Each photo being taken, until it's answered.
    private var photos: [Int64: PhotoCapture] = [:]

    /// The recording under way, by its temporary file.
    private var recordings: [URL: Recording] = [:]

    private var observers: [NSObjectProtocol] = []

    // MARK: The session's queue

    private var videoDevice: AVCaptureDevice?

    private var videoInput: AVCaptureDeviceInput?

    private var audioInput: AVCaptureDeviceInput?

    /// The device's zoom that's the guest's 1, and what the device can do.
    private var zoomBase = 1.0

    private var deviceZoom: ClosedRange<Double> = 1 ... 1

    init(camera: HostCameraCapture) {
        self.camera = camera
        super.init()
        observe()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Released by the guest: the camera goes off.
        let session = session, movieOutput = movieOutput
        queue.async {
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
            session.stopRunning()
        }
    }

    // MARK: The camera

    func start(_ position: CameraPosition) {
        generation += 1
        let generation = generation
        isOn = true
        isInterrupted = false
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.configure(position)
            if case .success = result, !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                switch result {
                case .success(let started):
                    self.zoomRange = started.zoom
                    self.zoomFactor = 1
                    self.hasFlash = started.hasFlash
                    self.camera?.started(minimumZoom: started.zoom.lowerBound, maximumZoom: started.zoom.upperBound,
                                         hasFlash: started.hasFlash)
                case .failure(let error):
                    self.isOn = false
                    self.camera?.failed(error)
                }
            }
        }
    }

    private struct Started {
        var zoom: ClosedRange<Double>
        var hasFlash: Bool
    }

    /// Puts the position's device in the session, at the guest's zoom of
    /// 1. On the session's queue.
    private func configure(_ position: CameraPosition) -> Result<Started, CameraError> {
        guard let device = AVCameraPlatform.device(for: position) else {
            return .failure(.unavailable)
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failure(CameraValues.error(error, otherwise: .unavailable))
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        if let videoInput {
            session.removeInput(videoInput)
            self.videoInput = nil
        }
        guard session.canAddInput(input) else {
            return .failure(.busy)
        }
        session.addInput(input)
        videoInput = input
        videoDevice = device
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { return .failure(.unavailable) }
            session.addOutput(photoOutput)
        }
        configurePhotos(device)
        Self.unmirror(photoOutput.connection(with: .video))
        let zoom = configureZoom(device)
        let hasFlash = device.hasFlash && photoOutput.supportedFlashModes.contains(.on)
        return .success(Started(zoom: zoom, hasFlash: hasFlash))
    }

    /// Photos at the largest size the device makes.
    private func configurePhotos(_ device: AVCaptureDevice) {
        if #available(iOS 16, macOS 13, *) {
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photoOutput.maxPhotoDimensions = largest
            }
        } else {
            #if os(iOS)
            photoOutput.isHighResolutionCaptureEnabled = true
            #endif
        }
    }

    /// The device at the guest's 1, and the guest's range. On the
    /// session's queue.
    private func configureZoom(_ device: AVCaptureDevice) -> ClosedRange<Double> {
        #if os(iOS)
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomBase = CameraValues.zoomBase(hasUltraWide: hasUltraWide,
                                         switchOvers: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue))
        let minimum = Double(device.minAvailableVideoZoomFactor), maximum = Double(device.maxAvailableVideoZoomFactor)
        deviceZoom = minimum <= maximum ? minimum ... maximum : 1 ... 1
        setDeviceZoom(1)
        return CameraValues.zoomRange(minimum: minimum, maximum: maximum, base: zoomBase)
        #else
        // A Mac's cameras don't zoom.
        zoomBase = 1
        deviceZoom = 1 ... 1
        return 1 ... 1
        #endif
    }

    /// The guest's factor, on the device. On the session's queue.
    private func setDeviceZoom(_ factor: Double) {
        #if os(iOS)
        guard let device = videoDevice, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = CGFloat(CameraValues.deviceZoom(factor, base: zoomBase,
                                                                 minimum: deviceZoom.lowerBound, maximum: deviceZoom.upperBound))
        device.unlockForConfiguration()
        #endif
    }

    func stop() {
        generation += 1
        isOn = false
        isInterrupted = false
        queue.async { [session, movieOutput] in
            // The recording's file is finished, and reported, as it ends.
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
            session.stopRunning()
        }
    }

    func setZoom(_ factor: Double) {
        zoomFactor = factor
        queue.async { [weak self] in
            self?.setDeviceZoom(factor)
        }
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        flashMode = CameraValues.flashMode(mode)
    }

    // MARK: From the preview

    /// The zoom a pinch starts from.
    private var pinchStart = 1.0

    func pinchBegan() {
        pinchStart = zoomFactor
    }

    /// A pinch to `scale` times what it began at.
    func pinchChanged(_ scale: Double) {
        guard isOn, scale.isFinite, scale > 0 else { return }
        let factor = min(max(pinchStart * scale, zoomRange.lowerBound), zoomRange.upperBound)
        guard factor != zoomFactor else { return }
        setZoom(factor)
        camera?.zoomChanged(factor)
    }

    /// Focuses and sets the exposure at a point in the device's space,
    /// from (0, 0) to (1, 1).
    func focus(at point: CGPoint) {
        guard isOn else { return }
        queue.async { [weak self] in
            guard let device = self?.videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            #if os(iOS)
            // Back to the whole picture when the scene changes.
            device.isSubjectAreaChangeMonitoringEnabled = true
            #endif
            device.unlockForConfiguration()
        }
    }

    // MARK: Photos

    func capturePhoto(to path: String, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void) {
        let output = photoOutput
        let settings = output.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        if hasFlash, output.supportedFlashModes.contains(flashMode), #available(macOS 13, *) {
            settings.flashMode = flashMode
        }
        if #available(iOS 16, macOS 13, *) {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
        } else {
            #if os(iOS)
            settings.isHighResolutionPhotoEnabled = output.isHighResolutionCaptureEnabled
            #endif
        }
        let id = settings.uniqueID
        // The output keeps no hold on its delegate: this does, until it's
        // answered.
        photos[id] = PhotoCapture(url: URL(fileURLWithPath: path)) { [weak self] result in
            self?.photos[id] = nil
            completion(result)
        }
        let capture = photos[id]
        let upright = Self.upright()
        queue.async {
            guard let capture else { return }
            Self.turn(output.connection(with: .video), upright)
            output.capturePhoto(with: settings, delegate: capture)
        }
    }

    // MARK: Video

    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void) {
        let file = CameraValues.recordingFile()
        let recording = Recording(destination: URL(fileURLWithPath: path), file: file, started: completion)
        recordings[file] = recording
        let upright = Self.upright()
        queue.async { [weak self] in
            guard let self else { return }
            if let error = self.prepareRecording(audio: audio) {
                self.restoreAfterRecording()
                DispatchQueue.main.async {
                    self.recordings[file] = nil
                    completion(error)
                }
                return
            }
            let connection = self.movieOutput.connection(with: .video)
            #if os(iOS)
            if let connection, self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                // H.264, which an MP4 file carries everywhere, rather than
                // the HEVC a newer phone would choose.
                self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
            #endif
            Self.unmirror(connection)
            Self.turn(connection, upright)
            self.movieOutput.startRecording(to: file, recordingDelegate: self)
        }
    }

    /// Video at the usual size, and sound if it's wanted. On the session's
    /// queue.
    private func prepareRecording(audio: Bool) -> CameraError? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        if audio {
            guard let microphone = AVCameraPlatform.microphone,
                  let input = try? AVCaptureDeviceInput(device: microphone),
                  session.canAddInput(input) else {
                return .unavailable
            }
            session.addInput(input)
            audioInput = input
        }
        if !session.outputs.contains(movieOutput) {
            guard session.canAddOutput(movieOutput) else { return .unavailable }
            session.addOutput(movieOutput)
        }
        return nil
    }

    /// Back to taking photos. On the session's queue.
    private func restoreAfterRecording() {
        session.beginConfiguration()
        if session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }
        if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        session.commitConfiguration()
    }

    func stopRecording() {
        queue.async { [movieOutput] in
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
        }
    }

    /// The recording's file, as an MP4 at the place asked for: rewrapped,
    /// not encoded again. What can't be rewrapped stays a QuickTime movie.
    private static func finish(_ recording: Recording, completion: @escaping (_ mimeType: String) -> Void) {
        let destination = recording.destination, file = recording.file
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: file)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              export.supportedFileTypes.contains(.mp4) else {
            completion(keep(file, at: destination))
            return
        }
        export.outputURL = destination
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            if export.status == .completed {
                try? FileManager.default.removeItem(at: file)
                completion(CameraValues.mp4)
            } else {
                try? FileManager.default.removeItem(at: destination)
                completion(keep(file, at: destination))
            }
        }
    }

    /// The movie as it was recorded, at the place asked for.
    private static func keep(_ file: URL, at destination: URL) -> String {
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
        return CameraValues.quickTime
    }

    // MARK: What the system does

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] notification in
            self?.runtimeError(notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            // Leaving the front is the host's to report, and has been.
            guard reason != .videoDeviceNotAvailableInBackground else { return }
            self?.interruptionBegan()
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.interruptionEnded()
        })
        #endif
    }

    private func interruptionBegan() {
        guard isOn, !isInterrupted else { return }
        isInterrupted = true
        camera?.interruptionBegan()
    }

    private func interruptionEnded() {
        guard isInterrupted else { return }
        isInterrupted = false
        camera?.interruptionEnded()
    }

    private func runtimeError(_ error: NSError?) {
        guard isOn else { return }
        #if os(iOS)
        if error?.code == CameraValues.Code.mediaServicesWereReset {
            // The system's media services restarted: so does the camera.
            queue.async { [session] in
                session.startRunning()
            }
            return
        }
        #endif
        isOn = false
        camera?.failed(CameraValues.error(error, otherwise: .unknown))
    }

    // MARK: Which way up

    /// How the device is held now, which a capture is turned to stand
    /// upright. `nil` on a Mac, whose pictures are as they come.
    private static func upright() -> CameraValues.Upright? {
        #if os(iOS)
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .upsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default:
            // Flat on a table: as the app's interface is.
            let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
            switch scene?.interfaceOrientation {
            case .portraitUpsideDown?: return .upsideDown
            // The interface turns against the device.
            case .landscapeLeft?: return .landscapeRight
            case .landscapeRight?: return .landscapeLeft
            default: return .portrait
            }
        }
        #else
        return nil
        #endif
    }

    private static func turn(_ connection: AVCaptureConnection?, _ upright: CameraValues.Upright?) {
        guard let connection, let upright else { return }
        if #available(iOS 17, macOS 14, *) {
            if connection.isVideoRotationAngleSupported(upright.rotationAngle) {
                connection.videoRotationAngle = upright.rotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = upright.videoOrientation
        }
    }

    /// Files aren't mirrored, whichever camera took them.
    private static func unmirror(_ connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }
}

// MARK: Recording

extension AVCameraEngine: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            guard let recording = self.recordings[fileURL], !recording.hasStarted else { return }
            recording.hasStarted = true
            recording.started(nil)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        queue.async {
            self.restoreAfterRecording()
        }
        DispatchQueue.main.async {
            guard let recording = self.recordings.removeValue(forKey: fileURL) else { return }
            guard recording.hasStarted, CameraValues.keptFile(error) else {
                try? FileManager.default.removeItem(at: fileURL)
                if recording.hasStarted {
                    // Begun, and nothing kept.
                    self.camera?.recordingFinished(duration: 0, mimeType: CameraValues.mp4,
                                                   error: CameraValues.recordingInterruption(error) ?? .writeFailed)
                } else {
                    recording.hasStarted = true
                    recording.started(CameraValues.error(error, otherwise: .unavailable))
                }
                return
            }
            let interruption = CameraValues.recordingInterruption(error)
            let duration = AVURLAsset(url: fileURL).duration.seconds
            Self.finish(recording) { mimeType in
                DispatchQueue.main.async {
                    self.camera?.recordingFinished(duration: duration.isFinite ? duration : 0, mimeType: mimeType, error: interruption)
                }
            }
        }
    }
}

/// A recording, from asking to its file being whole. Main thread.
private final class Recording {

    let destination: URL

    /// Where the movie file output writes, before it's rewrapped.
    let file: URL

    let started: (CameraError?) -> Void

    var hasStarted = false

    init(destination: URL, file: URL, started: @escaping (CameraError?) -> Void) {
        self.destination = destination
        self.file = file
        self.started = started
    }
}

// MARK: A photo

/// One photo, from asking to its file being written. It's answered once,
/// on the main thread.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {

    let url: URL

    private let completion: (Result<(width: Int, height: Int), CameraError>) -> Void

    /// On the photo output's queue.
    private var isAnswered = false

    init(url: URL, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void) {
        self.url = url
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            answer(.failure(CameraValues.error(error, otherwise: .unknown)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            answer(.failure(.unknown))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            answer(.failure(.writeFailed))
            return
        }
        guard let size = CameraValues.uprightSize(ofImageAt: url) else {
            answer(.failure(.writeFailed))
            return
        }
        answer(.success(size))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        // Every photo ends here: one that was never processed fails.
        answer(.failure(CameraValues.error(error, otherwise: .unknown)))
    }

    private func answer(_ result: Result<(width: Int, height: Int), CameraError>) {
        guard !isAnswered else { return }
        isAnswered = true
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}
