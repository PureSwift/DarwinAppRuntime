import DynamicPhotos
import DynamicRuntime
import Foundation
import Photos
import UniformTypeIdentifiers

/// Between PhotoKit's values and the guest's.
enum PhotoValues {

    // MARK: Access

    /// The manifest's `.photoLibrary(.addOnly, …)`:
    /// `RTCapabilityOptions.photoLibrary.access`. Browsing is the default.
    static func allowsReading(_ info: [String: Any]) -> Bool {
        let options = info["RTCapabilityOptions"] as? [String: Any]
        let access = (options?["photoLibrary"] as? [String: Any])?["access"] as? String
        return access != "addOnly"
    }

    /// What the user has granted, from what the system says of each level.
    /// An app that browses is asked for reading while it hasn't been, even
    /// when it was given adding.
    static func access(readWrite: PHAuthorizationStatus, addOnly: PHAuthorizationStatus, allowsReading: Bool) -> PhotoLibraryAccess {
        switch readWrite {
        case .authorized:
            return allowsReading ? .authorized : .addOnly
        case .limited:
            return allowsReading ? .limited : .addOnly
        case .denied where allowsReading:
            return .denied
        case .restricted where allowsReading:
            return .restricted
        default:
            break
        }
        switch addOnly {
        case .authorized, .limited:
            return .addOnly
        case .denied:
            return allowsReading ? .notDetermined : .denied
        case .restricted:
            return allowsReading ? .notDetermined : .restricted
        default:
            return .notDetermined
        }
    }

    /// The level the system is asked for: what the manifest declares.
    static func level(allowsReading: Bool) -> PHAccessLevel {
        allowsReading ? .readWrite : .addOnly
    }

    /// Photo library access as the built-in `Permissions` contract reports
    /// it, as AppRuntime's `PhotosPermission` does.
    static func permission(_ access: PhotoLibraryAccess, allowsReading: Bool) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .limited: return .limited
        case .unavailable: return .unavailable
        // All an app that only adds asked for; for one that browses, the
        // question hasn't been put.
        case .addOnly: return allowsReading ? .notDetermined : .granted
        }
    }

    // MARK: Errors

    /// What the guest is told of a failure. `otherwise` is for what PhotoKit
    /// doesn't say.
    static func error(_ error: (any Error)?, otherwise: PhotoLibraryError = .unknown) -> PhotoLibraryError {
        guard let error = error as NSError?, error.domain == PHPhotosErrorDomain else { return otherwise }
        // By code: most of PhotoKit's are newer than the deployment target.
        switch error.code {
        case 3072:                      // userCancelled
            return .cancelledByUser
        case 3310, 3311:                // accessRestricted, accessUserDenied
            return .notAuthorized
        case 3164, 3169,                // networkAccessRequired, networkError
             3114, 3142, 3143:          // the library's volume or bundle went away
            return .unavailable
        case 3201, 3303:                // identifierNotFound, missingResource
            return .notFound
        case 3302:                      // invalidResource
            return .invalidData
        default:
            return otherwise
        }
    }

    // MARK: Assets

    /// The kind of a PhotoKit asset; `nil` for audio, which the library
    /// isn't for.
    static func kind(_ mediaType: PHAssetMediaType) -> PhotoKind? {
        switch mediaType {
        case .image: return .image
        case .video: return .video
        default: return nil
        }
    }

    /// Milliseconds since 1970; 0 for an asset with no date.
    static func milliseconds(_ date: Date?) -> Int64 {
        guard let interval = date?.timeIntervalSince1970, interval.isFinite else { return 0 }
        return Int64((interval * 1000).rounded())
    }

    static func asset(_ asset: PHAsset) -> PhotoAsset? {
        guard let kind = kind(asset.mediaType) else { return nil }
        return PhotoAsset(
            id: asset.localIdentifier,
            kind: kind,
            creationDate: milliseconds(asset.creationDate),
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: kind == .video ? asset.duration : 0,
            isFavorite: asset.isFavorite
        )
    }

    /// Newest first, of `kind` or of both: never audio, nor hidden assets.
    static func fetchOptions(_ kind: PhotoKind?, sorted: Bool = true) -> PHFetchOptions {
        let options = PHFetchOptions()
        if sorted {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        switch kind {
        case .image?:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .video?:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case nil:
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }
        return options
    }

    // MARK: Albums

    /// Which albums the guest sees, and as which kind. Shared albums, the
    /// ones a sync made of events and faces, and the hidden photos aren't
    /// in the contract; nor is Recents, which is the whole library.
    static func albumKind(_ type: PHAssetCollectionType, _ subtype: PHAssetCollectionSubtype) -> PhotoAlbum.Kind? {
        switch type {
        case .album:
            switch subtype {
            case .albumRegular, .albumSyncedAlbum, .albumImported:
                return .user
            default:
                return nil
            }
        case .smartAlbum:
            switch subtype {
            case .smartAlbumAllHidden, .smartAlbumUserLibrary:
                return nil
            default:
                // The system's own, which aren't public, are past these.
                return subtype.rawValue < 1_000_000_000 ? .smart : nil
            }
        default:
            return nil
        }
    }

    // MARK: Originals

    /// Which of an asset's resources is its original: the photo or the
    /// video as it was taken, not an edit of it, and not a Live Photo's
    /// movie.
    static func original(_ types: [PHAssetResourceType], kind: PhotoKind) -> Int? {
        let wanted: [PHAssetResourceType] = kind == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .alternatePhoto, .fullSizePhoto]
        for type in wanted {
            if let index = types.firstIndex(of: type) {
                return index
            }
        }
        return nil
    }

    /// A resource's MIME type, by its type identifier or else its name.
    static func mimeType(typeIdentifier: String, name: String) -> String {
        if let type = UTType(typeIdentifier), let mime = type.preferredMIMEType {
            return mime
        }
        let ext = URL(fileURLWithPath: name).pathExtension
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// The name the original's copy has: the library's name for it, made
    /// safe for a path, or the kind's with the type's extension.
    static func fileName(_ original: String, typeIdentifier: String, kind: PhotoKind) -> String {
        var name = original
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") {
            name = kind == .video ? "Video" : "Photo"
            if let ext = UTType(typeIdentifier)?.preferredFilenameExtension {
                name += "." + ext
            }
        }
        return name
    }
}
