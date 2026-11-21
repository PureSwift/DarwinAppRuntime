import AVFoundation
import AVKit
import DynamicMedia
import RuntimeMedia
import SwiftUI

/// What a `VideoPlayer` node shows: the picture of the player whose
/// `identifier()` it carries, or nothing once the guest released it.
///
/// With `controls: .platform` it's AVKit's player view, whose buttons act
/// on the player; the player reports what they did. With `.none` it's
/// the picture alone. The player keeps playing when the node goes.
struct MediaVideoView: View {

    let identifier: Int32

    let scaling: VideoScaling

    let controls: VideoControls

    var body: some View {
        if let engine = HostMediaPlayback.player(for: identifier)?.engine as? AVMediaEngine {
            PlatformPlayerView(player: engine.player, gravity: MediaValues.gravity(scaling), controls: controls)
        }
    }
}

#if os(iOS)
import UIKit

private struct PlatformPlayerView: UIViewControllerRepresentable {

    let player: AVPlayer

    let gravity: AVLayerVideoGravity

    let controls: VideoControls

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // The host says what's playing, from what the app said.
        controller.updatesNowPlayingInfoCenter = false
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        update(controller)
    }

    private func update(_ controller: AVPlayerViewController) {
        if controller.player !== player {
            controller.player = player
        }
        controller.videoGravity = gravity
        controller.showsPlaybackControls = controls == .platform
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

#elseif os(macOS)
import AppKit

private struct PlatformPlayerView: NSViewRepresentable {

    let player: AVPlayer

    let gravity: AVLayerVideoGravity

    let controls: VideoControls

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.updatesNowPlayingInfoCenter = false
        update(view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        update(view)
    }

    private func update(_ view: AVPlayerView) {
        if view.player !== player {
            view.player = player
        }
        view.videoGravity = gravity
        view.controlsStyle = controls == .platform ? .inline : .none
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
#endif
