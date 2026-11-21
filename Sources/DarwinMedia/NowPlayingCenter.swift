import Foundation
import MediaPlayer
import RuntimeMedia
#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

/// What's playing, where the system shows it: `MPNowPlayingInfoCenter`,
/// and the buttons there and on headphones and keyboards,
/// `MPRemoteCommandCenter`.
///
/// `HostMediaPlayback` says what to show at each change of state, and
/// answers the buttons: play, pause and seeking on the player; next and
/// previous through the guest.
final class NowPlayingCenter {

    private var hasTargets = false

    /// The artwork last read, and what it was read from: it's read once.
    private var artwork: (source: HostArtwork, artwork: MPMediaItemArtwork?)?

    func show(_ nowPlaying: HostNowPlaying?) {
        addTargets()
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        guard let nowPlaying else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            artwork = nil
            for command in Self.commands(commands) {
                command.isEnabled = false
            }
            return
        }
        center.nowPlayingInfo = MediaValues.nowPlayingInfo(nowPlaying, artwork: artwork(nowPlaying.artwork))
        #if os(macOS)
        // macOS shows what the state says, not the rate.
        center.playbackState = nowPlaying.isPlaying ? .playing : .paused
        #endif
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        // A live stream can't be sought.
        commands.changePlaybackPositionCommand.isEnabled = nowPlaying.duration != nil
        let skips = nowPlaying.commands.contains(.skip)
        commands.skipBackwardCommand.isEnabled = skips
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: nowPlaying.skipBackward)]
        commands.skipForwardCommand.isEnabled = skips
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: nowPlaying.skipForward)]
        commands.nextTrackCommand.isEnabled = nowPlaying.commands.contains(.next)
        commands.previousTrackCommand.isEnabled = nowPlaying.commands.contains(.previous)
    }

    private static func commands(_ center: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.changePlaybackPositionCommand, center.skipBackwardCommand, center.skipForwardCommand,
            center.nextTrackCommand, center.previousTrackCommand,
        ]
    }

    /// Each button goes to `HostMediaPlayback.remote`, which says whether
    /// anything answered.
    private func addTargets() {
        guard !hasTargets else { return }
        hasTargets = true
        let center = MPRemoteCommandCenter.shared()
        func target(_ command: MPRemoteCommand, _ make: @escaping (MPRemoteCommandEvent) -> HostRemoteCommand?) {
            command.addTarget { event in
                guard let remote = make(event) else { return .commandFailed }
                return Self.onMain { HostMediaPlayback.remote(remote) } ? .success : .noActionableNowPlayingItem
            }
        }
        target(center.playCommand) { _ in .play }
        target(center.pauseCommand) { _ in .pause }
        target(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        target(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
        }
        target(center.skipBackwardCommand) { _ in .skipBackward }
        target(center.skipForwardCommand) { _ in .skipForward }
        target(center.nextTrackCommand) { _ in .next }
        target(center.previousTrackCommand) { _ in .previous }
    }

    /// The handlers are called on the main thread; `HostMediaPlayback` is
    /// main-thread only either way.
    private static func onMain(_ body: () -> Bool) -> Bool {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func artwork(_ source: HostArtwork?) -> MPMediaItemArtwork? {
        guard let source else { return nil }
        if let artwork, artwork.source == source {
            return artwork.artwork
        }
        let image: PlatformImage?
        switch source {
        case .file(let path):
            image = PlatformImage(contentsOfFile: path)
        case .data(let bytes, _):
            image = PlatformImage(data: Data(bytes))
        }
        let made = image.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        artwork = (source, made)
        return made
    }
}
