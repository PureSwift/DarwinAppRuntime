import AVFoundation
import DarwinHost
import DynamicMedia
import Foundation
import RuntimeMedia
#if canImport(UIKit)
import UIKit
#endif

/// `HostMediaPlayback`'s platform: `AVPlayer`s, what's playing in
/// `MPNowPlayingInfoCenter`, and on iOS the audio session and the app's
/// moves to the background.
final class DarwinMediaPlatform: MediaPlatform {

    let nowPlaying = NowPlayingCenter()

    private var observers: [NSObjectProtocol] = []

    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        AVMediaEngine(playback: player)
    }

    func canPlay(_ mimeType: String) -> MediaSupport {
        MediaValues.support(mimeType)
    }

    func showNowPlaying(_ nowPlaying: HostNowPlaying?) {
        self.nowPlaying.show(nowPlaying)
    }

    /// Listens for what pauses players: on iOS the background, an
    /// interruption and unplugged headphones. A Mac app isn't suspended,
    /// and its players go on when it isn't in front.
    func attach() {
        guard observers.isEmpty else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Media, not a game: it silences other apps' sound, and plays with
        // the ring/silent switch on silent.
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            AppHost.logger.error("Couldn't set the audio session's category: \(error.localizedDescription, privacy: .public)")
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                HostMediaPlayback.applicationDidEnterBackground()
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { notification in
                Self.interrupted(notification.userInfo ?? [:])
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                if reason == .oldDeviceUnavailable {
                    HostMediaPlayback.outputRouteWasLost()
                }
            },
        ]
        #endif
    }

    #if os(iOS)
    static func interrupted(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            HostMediaPlayback.interruptionBegan()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            HostMediaPlayback.interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }
    #endif

    /// Makes the session active before a player with sound plays, which
    /// takes the sound from other apps. It stays active, so a player that
    /// plays in the background keeps it there.
    static func activateSession(muted: Bool) {
        #if os(iOS)
        guard !muted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppHost.logger.error("Couldn't activate the audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}
