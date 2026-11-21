import DarwinFiles
import DarwinHost
import DarwinUI
import DynamicMedia
import DynamicRuntime
import Foundation
import RuntimeMedia
import RuntimeNative
import SwiftUI

/// The media contracts (`HostRuntime.md` §5.9): `MediaPlayback`, with its
/// `MediaPlaybackDelegate`, and what's playing.
///
/// The contract is AppRuntime's `HostMediaPlayback`, which checks each
/// source, keeps which player is the app's now-playing one and applies the
/// rules for the background and interruptions. This module gives it
/// `AVPlayer`s (`AVMediaEngine`), `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter` (`NowPlayingCenter`), and the audio session.
///
/// Registering it also gives the SwiftUI renderer its `VideoPlayer` views.
public enum DarwinMedia: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostMediaModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // A source in the bundle or the app's files is found through
        // `HostFiles`, whether or not the app uses `Files` itself.
        DarwinFiles.configureIfNeeded()
        let info = Bundle.main.infoDictionary ?? [:]
        HostMediaPlayback.platform = platform
        // The guest's `Clock`, so the times reported are on its timeline.
        HostMediaPlayback.clock = (registrar as? NativeRuntime)?.runtime.clock ?? DispatchClock()
        HostMediaPlayback.allowsNetwork = MediaValues.declares("network", info)
        HostMediaPlayback.allowsBackground = MediaValues.allowsBackground(info)
        HostMediaModule.register(in: registrar)
        VideoPlayers.provider = { identifier, scaling, controls in
            AnyView(MediaVideoView(identifier: identifier,
                                   scaling: scaling.flatMap(VideoScaling.init(rawValue:)) ?? .fit,
                                   controls: controls.flatMap(VideoControls.init(rawValue:)) ?? .platform))
        }
        platform.attach()
    }

    /// No platform asks the user before an app plays sound.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.audio: GrantedPermission()]
    }

    nonisolated(unsafe) static let platform = DarwinMediaPlatform()
}
