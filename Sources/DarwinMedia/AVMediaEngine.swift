import AVFoundation
import DynamicMedia
import Foundation
import RuntimeMedia

/// `HostMediaPlayback`'s engine: an `AVPlayer`, one source at a time.
///
/// AVFoundation decodes, keeps time and syncs sound to picture on its own
/// threads. This reads what the player and its item say, on the main
/// thread, and reports it to the `HostMediaPlayback` it was made for.
/// A `VideoPlayer` node shows `player`.
final class AVMediaEngine: NSObject, MediaEngine {

    let player = AVPlayer()

    private weak var playback: HostMediaPlayback?

    /// What was last reported of the player: `nil` until the source has
    /// loaded.
    private var reported: MediaState?

    /// A pause this engine asked for. One the player reports that this
    /// didn't ask for is the user's, from the platform's controls.
    private var expectsPause = false

    private var rate: Float = 1

    private var looping = false

    private var interval = 0.5

    private var timeObserver: Any?

    private var playerObservations: [NSKeyValueObservation] = []

    private var itemObservations: [NSKeyValueObservation] = []

    private var itemObservers: [NSObjectProtocol] = []

    /// `loadData`'s bytes, as a file AVFoundation reads.
    private var temporaryFile: URL?

    /// Whether the source is a file or bytes, which the host found: one
    /// that won't load isn't a format AVFoundation plays.
    private var isLocal = false

    init(playback: HostMediaPlayback) {
        self.playback = playback
        super.init()
        player.actionAtItemEnd = .pause
        // The host pauses a player that doesn't play in the background
        // itself; one that does goes on, its picture stopped.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let changed: (AVPlayer, Any) -> Void = { [weak self] _, _ in
            // After what's queued on the main thread, so an interruption's
            // or the background's pause is known before the player's is
            // reported.
            DispatchQueue.main.async { self?.playerChanged() }
        }
        playerObservations = [
            player.observe(\.timeControlStatus, changeHandler: changed),
            player.observe(\.reasonForWaitingToPlay, changeHandler: changed),
        ]
        addTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        clearItem()
    }

    // MARK: Loading

    func load(_ source: HostMediaSource) {
        clearItem()
        let url: URL
        isLocal = true
        switch source {
        case .url(let string):
            guard let found = URL(string: string) else {
                playback?.failed(MediaError(.notFound, message: "not a URL"))
                return
            }
            url = found
            isLocal = false
        case .file(let path):
            url = URL(fileURLWithPath: path)
        case .data(let bytes, let mimeType):
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("media-\(UUID().uuidString)")
                .appendingPathExtension(MediaValues.fileExtension(mimeType))
            do {
                try Data(bytes).write(to: file)
            } catch {
                playback?.failed(MediaError(.unavailable, message: "couldn't keep the data: \(error.localizedDescription)"))
                return
            }
            temporaryFile = file
            url = file
        }
        let item = AVPlayerItem(url: url)
        // The contract's rates keep the pitch.
        item.audioTimePitchAlgorithm = .spectral
        itemObservations = [
            item.observe(\.status) { [weak self] _, _ in
                DispatchQueue.main.async { self?.statusChanged(item) }
            },
            item.observe(\.loadedTimeRanges) { [weak self] _, _ in
                DispatchQueue.main.async { self?.bufferChanged(item) }
            },
        ]
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.reachedEnd()
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.fail(error)
            },
        ]
        // Paused at the start.
        player.pause()
        player.replaceCurrentItem(with: item)
    }

    func unload() {
        clearItem()
    }

    private func clearItem() {
        itemObservations = []
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        reported = nil
        expectsPause = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let temporaryFile {
            try? FileManager.default.removeItem(at: temporaryFile)
            self.temporaryFile = nil
        }
    }

    private func statusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem, reported == nil else { return }
        switch item.status {
        case .readyToPlay:
            let types = Set(item.tracks.compactMap { $0.assetTrack?.mediaType })
            let size = item.presentationSize
            let hasVideo = types.contains(.video) || size != .zero
            // A stream whose tracks aren't known yet is taken to have sound.
            let hasAudio = types.isEmpty || types.contains(.audio)
            reported = .paused
            playback?.loaded(duration: MediaValues.seconds(item.duration), width: Int(size.width.rounded()),
                             height: Int(size.height.rounded()), hasAudio: hasAudio, hasVideo: hasVideo)
        case .failed:
            fail(item.error)
        default:
            break
        }
    }

    private func fail(_ error: Error?) {
        var failure = MediaValues.error(error)
        // AVFoundation says only that it stopped.
        if reported == nil, isLocal, failure.code == .unknown {
            failure = MediaError(.unsupportedFormat, message: failure.message)
        }
        reported = .failed
        playback?.failed(failure)
    }

    // MARK: Playing

    func play() {
        guard player.currentItem != nil else { return }
        if isAtEnd {
            player.seek(to: .zero)
        }
        expectsPause = false
        DarwinMediaPlatform.activateSession(muted: player.isMuted)
        player.rate = rate
    }

    func pause() {
        guard player.timeControlStatus != .paused else { return }
        expectsPause = true
        player.pause()
    }

    /// What the player is doing, as the contract has it. Waiting before it
    /// starts, which it does at every start, isn't buffering.
    private func playerChanged() {
        guard let current = reported, current != .failed, let playback else { return }
        let state: MediaState
        switch player.timeControlStatus {
        case .playing:
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            guard player.reasonForWaitingToPlay == .toMinimizeStalls else { return }
            state = .buffering
        case .paused:
            // At the end the item's notification says so, or it loops.
            guard !isAtEnd else { return }
            state = .paused
        @unknown default:
            return
        }
        guard state != current else { return }
        reported = state
        reportTime()
        if state == .paused {
            let reason: MediaPauseReason = expectsPause ? .requested : .user
            expectsPause = false
            playback.stateChanged(.paused, reason: reason)
        } else {
            playback.stateChanged(state)
        }
    }

    private func reachedEnd() {
        guard reported != nil else { return }
        if looping {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.player.rate = self.rate
                    self.reportTime()
                }
            }
            return
        }
        reported = .paused
        reportTime(rate: 0)
        playback?.ended()
    }

    private var isAtEnd: Bool {
        guard let item = player.currentItem, let duration = MediaValues.seconds(item.duration) else { return false }
        return currentTime >= duration - 0.05
    }

    // MARK: Time

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    func seek(to position: Double, completion: @escaping (Bool) -> Void) {
        guard player.currentItem != nil else {
            completion(false)
            return
        }
        // Exactly there, where the format lets it.
        let time = CMTime(seconds: max(position, 0), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            DispatchQueue.main.async { completion(finished) }
        }
    }

    private func reportTime(rate: Float? = nil) {
        let advancing = reported == .playing
        playback?.timeChanged(position: currentTime, rate: rate ?? (advancing ? player.rate : 0))
    }

    private func addTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        let every = CMTime(seconds: interval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: every, queue: .main) { [weak self] _ in
            guard let self, self.reported == .playing else { return }
            self.reportTime()
        }
    }

    func setTimeUpdateInterval(_ seconds: Double) {
        interval = seconds
        addTimeObserver()
    }

    private func bufferChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem, reported != nil else { return }
        playback?.bufferChanged(MediaValues.buffered(item.loadedTimeRanges.map(\.timeRangeValue), at: currentTime))
    }

    // MARK: Settings

    func setRate(_ rate: Float) {
        self.rate = rate
        guard player.timeControlStatus != .paused else { return }
        player.rate = rate
        reportTime()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setLooping(_ looping: Bool) {
        self.looping = looping
    }
}
