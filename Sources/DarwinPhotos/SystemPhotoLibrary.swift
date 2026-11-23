import DynamicPhotos
import Foundation
import Photos
import RuntimePhotos

/// The user's photo library through PhotoKit: the `PhotoStore` behind
/// `HostPhotos`.
///
/// `HostPhotos` calls it off the main thread, one call at a time, once it
/// has checked access. With limited access PhotoKit itself shows only the
/// photos the user chose, and what the app added.
final class SystemPhotoLibrary: PhotoStore, @unchecked Sendable {

    let library: PHPhotoLibrary

    /// Where originals are written for the guest.
    let parent: URL

    /// The prefix of each original's folder, so only those are removed.
    static let folderPrefix = "PhotoOriginal-"

    init(library: PHPhotoLibrary = .shared(), parent: URL = FileManager.default.temporaryDirectory) {
        self.library = library
        self.parent = parent
    }

    // MARK: Adding

    func add(fileAt path: String, kind: PhotoKind) throws(PhotoLibraryError) -> PhotoAsset {
        let url = URL(fileURLWithPath: path)
        var identifier: String?
        do {
            try library.performChangesAndWait {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Copied in: the app keeps its own.
                options.shouldMoveFile = false
                options.originalFilename = url.lastPathComponent
                request.addResource(with: kind == .video ? .video : .photo, fileURL: url, options: options)
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            // `HostPhotos` has read the file's first bytes: what PhotoKit
            // refuses is what it can't read.
            throw PhotoValues.error(error, otherwise: .invalidData)
        }
        guard let identifier else { throw .unknown }
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject.flatMap(PhotoValues.asset) {
            return asset
        }
        // An app that may only add can't read back what it added. The
        // shared host tells it nothing of it anyway.
        return PhotoAsset(id: identifier, kind: kind, creationDate: PhotoValues.milliseconds(Date()))
    }

    // MARK: Browsing

    func identifiers(of kind: PhotoKind?, in album: String?) throws(PhotoLibraryError) -> [String] {
        let options = PhotoValues.fetchOptions(kind)
        let result: PHFetchResult<PHAsset>
        if let album {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
                throw .notFound
            }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
    }

    func assets(withIDs identifiers: [String]) throws(PhotoLibraryError) -> [PhotoAsset] {
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if let value = PhotoValues.asset(asset) {
                assets.append(value)
            }
        }
        return assets
    }

    func albums() throws(PhotoLibraryError) -> [PhotoAlbum] {
        let counting = PhotoValues.fetchOptions(nil, sorted: false)
        var albums: [PhotoAlbum] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                guard let kind = PhotoValues.albumKind(collection.assetCollectionType, collection.assetCollectionSubtype) else {
                    return
                }
                let count = PHAsset.fetchAssets(in: collection, options: counting).count
                // The system keeps many it has nothing in: Bursts, Slo-mo.
                if kind == .smart, count == 0 { return }
                albums.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count, kind: kind))
            }
        }
        return albums
    }

    // MARK: Originals

    func original(of identifier: String) throws(PhotoLibraryError) -> HostPhotoOriginal {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let kind = PhotoValues.kind(asset.mediaType) else {
            throw .notFound
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let index = PhotoValues.original(resources.map(\.type), kind: kind) else {
            throw .notFound
        }
        let resource = resources[index]
        let name = PhotoValues.fileName(resource.originalFilename, typeIdentifier: resource.uniformTypeIdentifier, kind: kind)
        let folder = parent.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .unavailable
        }
        // Fetched from the cloud if it must be. The answer comes on a queue
        // of PhotoKit's, not this one.
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let done = DispatchSemaphore(value: 0)
        var failure: (any Error)?
        PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure {
            try? FileManager.default.removeItem(at: folder)
            throw PhotoValues.error(failure, otherwise: .unavailable)
        }
        return HostPhotoOriginal(
            path: file.path,
            contentType: PhotoValues.mimeType(typeIdentifier: resource.uniformTypeIdentifier, name: name),
            name: resource.originalFilename.isEmpty ? nil : name
        )
    }

    func release(_ original: HostPhotoOriginal) {
        Self.remove(original.path)
    }

    /// Removes the folder an original was written to, and nothing that
    /// isn't one.
    static func remove(_ path: String) {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
