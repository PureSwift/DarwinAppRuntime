import DynamicPhotos
import DynamicRuntime
import Foundation
import Photos
import Testing
@testable import DarwinPhotos

/// Between PhotoKit's values and the guest's. Nothing here touches the
/// user's library, or asks them for it.
@Suite("Photo values")
struct PhotoValueTests {

    @Test func readsWhetherTheAppBrowses() {
        #expect(PhotoValues.allowsReading([:]))
        #expect(PhotoValues.allowsReading(["RTCapabilityOptions": ["photoLibrary": ["access": "readWrite"]]]))
        #expect(!PhotoValues.allowsReading(["RTCapabilityOptions": ["photoLibrary": ["access": "addOnly"]]]))
        #expect(PhotoValues.level(allowsReading: true) == .readWrite)
        #expect(PhotoValues.level(allowsReading: false) == .addOnly)
    }

    @Test func saysWhatAnAppThatBrowsesWasGranted() {
        func access(_ readWrite: PHAuthorizationStatus, _ addOnly: PHAuthorizationStatus = .notDetermined) -> PhotoLibraryAccess {
            PhotoValues.access(readWrite: readWrite, addOnly: addOnly, allowsReading: true)
        }
        #expect(access(.authorized) == .authorized)
        #expect(access(.limited) == .limited)
        #expect(access(.denied) == .denied)
        #expect(access(.restricted) == .restricted)
        #expect(access(.notDetermined) == .notDetermined)
        // Given adding alone, it still has to be asked for reading.
        #expect(access(.notDetermined, .authorized) == .addOnly)
        #expect(access(.notDetermined, .denied) == .notDetermined)
    }

    @Test func anAppThatOnlyAddsIsNeverMoreThanAddOnly() {
        func access(_ readWrite: PHAuthorizationStatus, _ addOnly: PHAuthorizationStatus) -> PhotoLibraryAccess {
            PhotoValues.access(readWrite: readWrite, addOnly: addOnly, allowsReading: false)
        }
        #expect(access(.notDetermined, .authorized) == .addOnly)
        #expect(access(.authorized, .authorized) == .addOnly)
        #expect(access(.limited, .notDetermined) == .addOnly)
        #expect(access(.notDetermined, .denied) == .denied)
        #expect(access(.notDetermined, .restricted) == .restricted)
        #expect(access(.notDetermined, .notDetermined) == .notDetermined)
        // Refusing reading says nothing of adding.
        #expect(access(.denied, .authorized) == .addOnly)
    }

    @Test func reportsAccessAsAPermission() {
        #expect(PhotoValues.permission(.authorized, allowsReading: true) == .granted)
        #expect(PhotoValues.permission(.limited, allowsReading: true) == .limited)
        #expect(PhotoValues.permission(.addOnly, allowsReading: false) == .granted)
        #expect(PhotoValues.permission(.addOnly, allowsReading: true) == .notDetermined)
        #expect(PhotoValues.permission(.unavailable, allowsReading: true) == .unavailable)
    }

    @Test func saysWhyItFailed() {
        func error(_ code: Int, otherwise: PhotoLibraryError = .unknown) -> PhotoLibraryError {
            PhotoValues.error(NSError(domain: PHPhotosErrorDomain, code: code), otherwise: otherwise)
        }
        #expect(error(3072) == .cancelledByUser)
        #expect(error(3311) == .notAuthorized)
        #expect(error(3164) == .unavailable)
        #expect(error(3201) == .notFound)
        #expect(error(3302) == .invalidData)
        #expect(error(-1) == .unknown)
        #expect(error(-1, otherwise: .invalidData) == .invalidData)
        #expect(PhotoValues.error(NSError(domain: NSCocoaErrorDomain, code: 3072), otherwise: .unavailable) == .unavailable)
        #expect(PhotoValues.error(nil) == .unknown)
    }

    @Test func readsAnAssetsKindAndDate() {
        #expect(PhotoValues.kind(.image) == .image)
        #expect(PhotoValues.kind(.video) == .video)
        #expect(PhotoValues.kind(.audio) == nil)
        #expect(PhotoValues.kind(.unknown) == nil)
        #expect(PhotoValues.milliseconds(Date(timeIntervalSince1970: 1_700_000_000.1234)) == 1_700_000_000_123)
        #expect(PhotoValues.milliseconds(nil) == 0)
    }

    @Test func fetchesNewestFirstAndNeverAudio() {
        let both = PhotoValues.fetchOptions(nil)
        #expect(both.sortDescriptors?.first?.key == "creationDate")
        #expect(both.sortDescriptors?.first?.ascending == false)
        #expect(both.predicate?.predicateFormat == "mediaType == 1 OR mediaType == 2")
        #expect(PhotoValues.fetchOptions(.image).predicate?.predicateFormat == "mediaType == 1")
        #expect(PhotoValues.fetchOptions(.video).predicate?.predicateFormat == "mediaType == 2")
        #expect(PhotoValues.fetchOptions(nil, sorted: false).sortDescriptors == nil)
    }

    @Test func showsTheUsersAlbumsAndTheSystemsOwn() {
        #expect(PhotoValues.albumKind(.album, .albumRegular) == .user)
        #expect(PhotoValues.albumKind(.album, .albumSyncedAlbum) == .user)
        #expect(PhotoValues.albumKind(.album, .albumCloudShared) == nil)
        #expect(PhotoValues.albumKind(.album, .albumSyncedFaces) == nil)
        #expect(PhotoValues.albumKind(.smartAlbum, .smartAlbumFavorites) == .smart)
        #expect(PhotoValues.albumKind(.smartAlbum, .smartAlbumVideos) == .smart)
        #expect(PhotoValues.albumKind(.smartAlbum, .smartAlbumScreenshots) == .smart)
        #expect(PhotoValues.albumKind(.smartAlbum, .smartAlbumAllHidden) == nil)
        #expect(PhotoValues.albumKind(.smartAlbum, .smartAlbumUserLibrary) == nil)
        // Recently Deleted, which isn't public.
        #expect(PhotoValues.albumKind(.smartAlbum, PHAssetCollectionSubtype(rawValue: 1_000_000_201)!) == nil)
    }

    @Test func copiesTheOriginalNotAnEdit() {
        #expect(PhotoValues.original([.adjustmentData, .fullSizePhoto, .photo], kind: .image) == 2)
        #expect(PhotoValues.original([.fullSizePhoto, .adjustmentData], kind: .image) == 0)
        // A Live Photo's picture, not its movie.
        #expect(PhotoValues.original([.pairedVideo, .photo], kind: .image) == 1)
        #expect(PhotoValues.original([.fullSizeVideo, .video], kind: .video) == 1)
        #expect(PhotoValues.original([.photo], kind: .video) == nil)
        #expect(PhotoValues.original([], kind: .image) == nil)
    }

    @Test func namesAndTypesTheCopy() {
        #expect(PhotoValues.mimeType(typeIdentifier: "public.heic", name: "IMG_1.HEIC") == "image/heic")
        #expect(PhotoValues.mimeType(typeIdentifier: "com.apple.quicktime-movie", name: "IMG_2.MOV") == "video/quicktime")
        #expect(PhotoValues.mimeType(typeIdentifier: "", name: "IMG_3.jpg") == "image/jpeg")
        #expect(PhotoValues.mimeType(typeIdentifier: "", name: "IMG_4") == "application/octet-stream")
        #expect(PhotoValues.fileName("IMG_0001.HEIC", typeIdentifier: "public.heic", kind: .image) == "IMG_0001.HEIC")
        #expect(PhotoValues.fileName("a/b:c.jpg", typeIdentifier: "public.jpeg", kind: .image) == "a-b-c.jpg")
        #expect(PhotoValues.fileName("", typeIdentifier: "com.apple.quicktime-movie", kind: .video) == "Video.mov")
        #expect(PhotoValues.fileName("../x", typeIdentifier: "public.png", kind: .image) == "Photo.png")
    }

    @Test func removesOnlyTheCopiesItMade() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DarwinPhotosTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let copy = parent.appendingPathComponent(SystemPhotoLibrary.folderPrefix + "1")
        let other = parent.appendingPathComponent("Other")
        for folder in [copy, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("IMG.jpg"))
        }
        SystemPhotoLibrary.remove(copy.appendingPathComponent("IMG.jpg").path)
        SystemPhotoLibrary.remove(other.appendingPathComponent("IMG.jpg").path)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("IMG.jpg").path))
    }
}
