import AVFoundation
import DynamicFiles
import DynamicMedia
import Foundation
import MediaPlayer
import RuntimeHost
import RuntimeMedia
import Testing
@testable import DarwinMedia

@Suite("Media values")
struct MediaValuesTests {

    @Test func saysWhatItPlays() {
        // What every host plays.
        for type in ["video/mp4", "audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "AUDIO/MPEG; charset=binary"] {
            #expect(MediaValues.support(type) == .probably, "\(type)")
        }
        // HTTP Live Streaming, which AVFoundation plays without saying the codecs.
        #expect(MediaValues.support("application/vnd.apple.mpegurl") == .maybe)
        // Apple's players don't play WebM.
        #expect(MediaValues.support("video/webm") == .no)
        #expect(MediaValues.support("text/plain") == .no)
        // A type with its codecs, which AVFoundation says it plays.
        #expect(MediaValues.support("video/x-custom; codecs=\"avc1\"", isPlayable: { _ in true }) == .probably)
    }

    @Test func namesFilesByType() {
        #expect(MediaValues.fileExtension("audio/mpeg") == "mp3")
        #expect(MediaValues.fileExtension("audio/wav") == "wav")
        #expect(MediaValues.fileExtension("audio/mp4") == "m4a")
        #expect(MediaValues.fileExtension("video/quicktime") == "mov")
        #expect(MediaValues.fileExtension("audio/flac") == "flac")
        #expect(MediaValues.fileExtension("x-unknown/thing") == "bin")
    }

    @Test func saysWhyItFailed() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(MediaValues.error(offline).code == .network)
        let missing = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
        #expect(MediaValues.error(missing).code == .notFound)
        // AVFoundation's own error wraps the cause.
        let format = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: format])
        #expect(MediaValues.error(wrapped).code == .unsupportedFormat)
        let damaged = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
        #expect(MediaValues.error(damaged).code == .decoding)
        let http404 = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12938)])
        #expect(MediaValues.error(http404).code == .notFound)
        #expect(MediaValues.error(NSError(domain: "Elsewhere", code: 1)).code == .unknown)
        #expect(MediaValues.error(nil).code == .unknown)
    }

    @Test func readsTime() {
        #expect(MediaValues.seconds(CMTime(seconds: 2.5, preferredTimescale: 600)) == 2.5)
        // A live stream's duration.
        #expect(MediaValues.seconds(.indefinite) == nil)
        #expect(MediaValues.seconds(.invalid) == nil)
        let ranges = [
            CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 600), duration: CMTime(seconds: 4, preferredTimescale: 600)),
            CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600), duration: CMTime(seconds: 5, preferredTimescale: 600)),
        ]
        #expect(MediaValues.buffered(ranges, at: 1) == 3)
        #expect(MediaValues.buffered(ranges, at: 12) == 3)
        // Just before a range that's loading after a seek.
        #expect(abs(MediaValues.buffered(ranges, at: 9.8) - 5.2) < 0.0001)
        #expect(MediaValues.buffered(ranges, at: 6) == 0)
    }

    @Test func scalesThePicture() {
        #expect(MediaValues.gravity(.fit) == .resizeAspect)
        #expect(MediaValues.gravity(.fill) == .resizeAspectFill)
        #expect(MediaValues.gravity(.stretch) == .resize)
    }

    @Test func readsTheManifest() {
        let info: [String: Any] = [
            "RTCapabilities": ["audio", "network"],
            "RTCapabilityOptions": ["audio": ["background": "true"]],
        ]
        #expect(MediaValues.declares("network", info))
        #expect(!MediaValues.declares("bluetooth", info))
        #expect(MediaValues.allowsBackground(info))
        #expect(MediaValues.allowsBackground(["RTCapabilityOptions": ["audio": ["background": true]]]))
        #expect(!MediaValues.allowsBackground(["RTCapabilities": ["audio"]]))
    }
}

/// What a guest's player heard, in order.
final class RecordingDelegate: MediaPlaybackDelegate {

    var loaded: (duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool)?
    var states: [(state: MediaState, reason: MediaPauseReason)] = []
    var times: [(position: Double, rate: Float)] = []
    var seeks: [(request: Int32, finished: Bool)] = []
    var ended = 0
    var failure: MediaError.Code?
    var commands: [Int32] = []

    var state: MediaState? { states.last?.state }

    func didLoad(_ duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        loaded = (duration, width, height, hasAudio, hasVideo)
    }

    func didChangeState(_ state: Int32, reason: Int32) {
        states.append((MediaState(rawValue: state) ?? .empty, MediaPauseReason(rawValue: reason) ?? .requested))
    }

    func didChangeTime(_ position: Double, timestamp: Int64, rate: Float) {
        times.append((position, rate))
    }

    func didChangeBuffer(_ seconds: Double) { }

    func didSeek(_ request: Int32, finished: Bool) {
        seeks.append((request, finished))
    }

    func didEnd() {
        ended += 1
    }

    func didFail(_ code: Int32, message: String) {
        failure = MediaError.Code(rawValue: code)
    }

    func didReceiveCommand(_ command: Int32) {
        commands.append(command)
    }
}

/// `HostMediaPlayback` over this module's `AVPlayer`s, with real files.
/// The players share `HostMediaPlayback`'s settings, so one test at a time.
@Suite("Media players", .serialized)
@MainActor
struct MediaPlayerTests {

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DarwinMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HostMediaPlayback.reset()
        HostMediaPlayback.platform = DarwinMediaPlatform()
        try HostFiles.configure(HostFiles.Configuration(directories: [.caches: directory.path]))
    }

    /// A WAV file: 16-bit mono PCM at 8 kHz, a quiet tone.
    static func wav(seconds: Double) -> [UInt8] {
        let rate = 8000
        let samples = Int(Double(rate) * seconds)
        var data = [UInt8]()
        func append(_ value: UInt32, _ bytes: Int) {
            for index in 0..<bytes {
                data.append(UInt8((value >> (8 * UInt32(index))) & 0xFF))
            }
        }
        data += Array("RIFF".utf8)
        append(UInt32(36 + samples * 2), 4)
        data += Array("WAVEfmt ".utf8)
        append(16, 4)
        append(1, 2)                    // PCM
        append(1, 2)                    // mono
        append(UInt32(rate), 4)
        append(UInt32(rate * 2), 4)
        append(2, 2)
        append(16, 2)
        data += Array("data".utf8)
        append(UInt32(samples * 2), 4)
        for index in 0..<samples {
            let sample = Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 300)
            append(UInt32(UInt16(bitPattern: sample)), 2)
        }
        return data
    }

    func wait(_ what: String, timeout: Double = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting: \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func playsAFileToItsEnd() async throws {
        try Data(Self.wav(seconds: 0.6)).write(to: directory.appendingPathComponent("tone.wav"))
        let delegate = RecordingDelegate()
        let player = HostMediaPlayback.make(delegate)
        #expect(player.engine is AVMediaEngine)
        player.setTimeUpdateInterval(0.1)
        player.loadFile(FileDirectory.caches.rawValue, path: "tone.wav")
        // Asked before it's ready, so it plays once it is.
        player.play()
        try await wait("loaded") { delegate.loaded != nil }
        let loaded = try #require(delegate.loaded)
        #expect(abs(loaded.duration - 0.6) < 0.01)
        #expect(loaded.hasAudio)
        #expect(!loaded.hasVideo)
        #expect(loaded.width == 0)
        try await wait("ended") { delegate.ended == 1 }
        #expect(delegate.states.map(\.state) == [.loading, .paused, .playing, .paused])
        #expect(delegate.states.last?.reason == .ended)
        // It said where it was while it played, and at the end.
        #expect(delegate.times.contains { $0.rate == 1 })
        #expect(abs((delegate.times.last?.position ?? 0) - 0.6) < 0.05)
        #expect(delegate.times.last?.rate == 0)
        // Played again after the end, it starts over.
        player.play()
        try await wait("playing again") { delegate.state == .playing }
        #expect(delegate.times.last.map { $0.position < 0.3 } == true)
        player.pause()
        try await wait("paused") { delegate.state == .paused }
        #expect(delegate.states.last?.reason == .requested)
    }

    @Test func seeksExactly() async throws {
        let delegate = RecordingDelegate()
        let player = HostMediaPlayback.make(delegate)
        // Bytes in memory, which the engine keeps as a file.
        player.loadData(Self.wav(seconds: 2), mimeType: "audio/wav")
        try await wait("loaded") { delegate.state == .paused }
        player.seek(1.25, request: 7)
        try await wait("sought") { !delegate.seeks.isEmpty }
        #expect(delegate.seeks.first?.request == 7)
        #expect(delegate.seeks.first?.finished == true)
        #expect(abs(player.engine!.currentTime - 1.25) < 0.01)
        #expect(abs((delegate.times.last?.position ?? 0) - 1.25) < 0.01)
        player.unload()
        #expect(delegate.state == .empty)
    }

    @Test func loopsWithoutEnding() async throws {
        let delegate = RecordingDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.setLooping(true)
        player.loadData(Self.wav(seconds: 0.3), mimeType: "audio/wav")
        player.play()
        try await wait("playing") { delegate.state == .playing }
        // Past the end twice: it starts again each time, and is still playing.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(delegate.ended == 0)
        #expect(delegate.state == .playing)
        player.pause()
    }

    @Test func failsOnWhatIsntMedia() async throws {
        let delegate = RecordingDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadData(Array("not a sound".utf8), mimeType: "audio/mpeg")
        try await wait("failed") { delegate.failure != nil }
        #expect(delegate.state == .failed)
        #expect(delegate.failure == .unsupportedFormat)
    }

    @Test func showsWhatsPlaying() async throws {
        let delegate = RecordingDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadData(Self.wav(seconds: 1), mimeType: "audio/wav")
        try await wait("loaded") { delegate.state == .paused }
        player.setRemoteCommands(MediaRemoteCommands.next.rawValue, skipBackward: 0, skipForward: 0)
        player.setNowPlaying("Morning", artist: "The Examples", album: "Examples")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Morning")
        #expect(info?[MPMediaItemPropertyArtist] as? String == "The Examples")
        #expect(info?[MPMediaItemPropertyAlbumTitle] as? String == "Examples")
        #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 1)
        #expect(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        let commands = MPRemoteCommandCenter.shared()
        #expect(commands.nextTrackCommand.isEnabled)
        #expect(!commands.previousTrackCommand.isEnabled)
        #expect(!commands.skipForwardCommand.isEnabled)
        // Next goes to the guest; toggling plays the player.
        #expect(HostMediaPlayback.remote(.next))
        #expect(delegate.commands == [1])
        #expect(!HostMediaPlayback.remote(.previous))
        HostMediaPlayback.remote(.togglePlayPause)
        try await wait("playing") { delegate.state == .playing }
        // Said again at the change of state, with the rate.
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        HostMediaPlayback.remote(.pause)
        try await wait("paused") { delegate.state == .paused }
        #expect(delegate.states.last?.reason == .user)
        // Taken away, nothing is shown.
        player.setNowPlaying("", artist: nil, album: nil)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        #expect(!commands.nextTrackCommand.isEnabled)
    }
}
