import AVFoundation
import DynamicMedia
import Foundation
import MediaPlayer
import RuntimeMedia
import UniformTypeIdentifiers

/// The contract's values as AVFoundation's and MediaPlayer's, and back.
///
/// None of it needs a player, so the tests check it on its own.
enum MediaValues {

    // MARK: Formats

    /// What every host plays (`MediaPlayer.md`, Formats): H.264 and AAC in
    /// MP4, MP3 and WAV. AVFoundation plays them all.
    static let requiredTypes: Set<String> = [
        "video/mp4", "video/x-m4v", "video/quicktime",
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac",
        "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave",
    ]

    /// `probably` for the required formats, and for a type with its codecs
    /// that AVFoundation says it plays; `maybe` for one it plays without
    /// saying which codecs, such as HTTP Live Streaming.
    static func support(_ mimeType: String, isPlayable: (String) -> Bool = AVURLAsset.isPlayableExtendedMIMEType) -> MediaSupport {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if requiredTypes.contains(base) {
            return .probably
        }
        guard isPlayable(mimeType) else {
            return .no
        }
        return mimeType.lowercased().contains("codecs=") ? .probably : .maybe
    }

    /// The extension a file of `mimeType` takes: AVFoundation tells formats
    /// apart by it.
    static func fileExtension(_ mimeType: String) -> String {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch base {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": return "wav"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "video/mp4": return "mp4"
        case "video/x-m4v": return "m4v"
        case "video/quicktime": return "mov"
        default: return UTType(mimeType: base)?.preferredFilenameExtension ?? "bin"
        }
    }

    // MARK: Errors

    /// Why a source couldn't be played. AVFoundation wraps the cause, so
    /// each error down the chain is asked until one says.
    static func error(_ error: Error?) -> MediaError {
        var next = error.map { $0 as NSError }
        while let current = next {
            if let code = code(current) {
                return MediaError(code, message: current.localizedDescription)
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return MediaError(.unknown, message: error?.localizedDescription ?? "playback failed")
    }

    private static func code(_ error: NSError) -> MediaError.Code? {
        switch error.domain {
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorFileDoesNotExist, NSURLErrorNoPermissionsToReadFile:
                return .notFound
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .notPermitted
            default:
                return .network
            }
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: error.code) {
            case .fileFormatNotRecognized, .fileFailedToParse, .decoderNotFound, .formatUnsupported,
                 .contentIsProtected, .contentIsNotAuthorized:
                return .unsupportedFormat
            case .decodeFailed:
                return .decoding
            default:
                return nil
            }
        case "CoreMediaErrorDomain":
            // An HTTP 404 from the server.
            return error.code == -12938 ? .notFound : nil
        case NSCocoaErrorDomain:
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError ? .notFound : nil
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT) ? .notFound : nil
        default:
            return nil
        }
    }

    // MARK: Time

    /// Seconds, or `nil` when it isn't known, as for a live stream.
    static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric, !time.isIndefinite else { return nil }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : nil
    }

    /// Seconds loaded past `position`: the end of the range it's in.
    static func buffered(_ ranges: [CMTimeRange], at position: Double) -> Double {
        for range in ranges {
            guard let start = seconds(range.start), let end = seconds(range.end) else { continue }
            // A little slack: the range may start just after a seek lands.
            if start <= position + 0.5, end >= position {
                return max(end - position, 0)
            }
        }
        return 0
    }

    // MARK: Video

    static func gravity(_ scaling: VideoScaling) -> AVLayerVideoGravity {
        switch scaling {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }

    // MARK: Now playing

    /// `MPNowPlayingInfoCenter`'s info: what the app said, and the player's
    /// own position, duration and rate.
    static func nowPlayingInfo(_ nowPlaying: HostNowPlaying, artwork: MPMediaItemArtwork?) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: nowPlaying.position,
            MPNowPlayingInfoPropertyPlaybackRate: Double(nowPlaying.isPlaying ? nowPlaying.rate : 0),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: nowPlaying.duration == nil,
        ]
        info[MPMediaItemPropertyArtist] = nowPlaying.artist
        info[MPMediaItemPropertyAlbumTitle] = nowPlaying.album
        info[MPMediaItemPropertyPlaybackDuration] = nowPlaying.duration
        info[MPMediaItemPropertyArtwork] = artwork
        return info
    }

    // MARK: The manifest

    /// Whether the app declares a capability (`RTCapabilities`).
    static func declares(_ capability: String, _ info: [String: Any]) -> Bool {
        (info["RTCapabilities"] as? [String] ?? []).contains(capability)
    }

    /// `.audio(background: true)`: `RTCapabilityOptions.audio.background`,
    /// which the packager copies from the universal bundle as it is.
    static func allowsBackground(_ info: [String: Any]) -> Bool {
        let options = info["RTCapabilityOptions"] as? [String: Any]
        let background = (options?["audio"] as? [String: Any])?["background"]
        return background as? String == "true" || background as? Bool == true
    }
}
