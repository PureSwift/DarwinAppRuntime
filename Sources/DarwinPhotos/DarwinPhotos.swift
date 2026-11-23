import DarwinFiles
import DarwinHost
import DarwinUI
import DynamicPhotos
import DynamicRuntime
import Foundation
import Photos
import RuntimePhotos
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The photo library contract (`HostRuntime.md` §5.15): `Photos`, its
/// results, its files, its callback and its delegate.
///
/// The contract is AppRuntime's `HostPhotos`, which checks access before
/// every call, keeps an app that declared adding alone from reading, reads
/// a fetch a page at a time, makes an original a file grant and gathers a
/// burst of changes into one. This module gives it the user's library
/// through PhotoKit (`SystemPhotoLibrary`), the system's question, its
/// deletion, and the library's changes.
///
/// Registering it also gives the SwiftUI renderer its `Photo` views.
public enum DarwinPhotos: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostPhotosModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // What's added is found, and an original is granted, through
        // `HostFiles`, whether or not the app uses `Files` itself.
        DarwinFiles.configureIfNeeded()
        HostPhotos.store = SystemPhotoLibrary()
        HostPhotos.allowsReading = PhotoValues.allowsReading(Bundle.main.infoDictionary ?? [:])
        HostPhotos.access = currentAccess
        HostPhotos.requester = { completion in
            PHPhotoLibrary.requestAuthorization(for: PhotoValues.level(allowsReading: HostPhotos.allowsReading)) { _ in
                // What was granted, which may be some photos and not all.
                DispatchQueue.main.async {
                    let access = currentAccess
                    completion(access)
                    observeLibrary(access)
                }
            }
        }
        HostPhotos.deleter = delete
        HostPhotosModule.register(in: registrar)
        PhotoViews.provider = { asset, scaling in
            AnyView(PhotoNodeView(identifier: asset, fill: scaling != PhotoScaling.fit.rawValue))
        }
        observe()
    }

    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.photoLibrary: PhotoLibraryPermission()]
    }

    /// What the user has granted now, for what the manifest declares.
    /// Never asks.
    static var currentAccess: PhotoLibraryAccess {
        PhotoValues.access(
            readWrite: PHPhotoLibrary.authorizationStatus(for: .readWrite),
            addOnly: PHPhotoLibrary.authorizationStatus(for: .addOnly),
            allowsReading: HostPhotos.allowsReading
        )
    }

    // MARK: Deleting

    /// Deletes through PhotoKit, which asks the user first and says how
    /// many. All of them or none.
    static func delete(_ identifiers: [String], completion: @escaping (Result<Void, PhotoLibraryError>) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count == Set(identifiers).count else {
            completion(.failure(.notFound))
            return
        }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, error in
            DispatchQueue.main.async {
                completion(success ? .success(()) : .failure(PhotoValues.error(error)))
            }
        }
    }

    // MARK: Changes

    nonisolated(unsafe) private static var observing = false

    nonisolated(unsafe) private static var observer: LibraryObserver?

    /// What the user granted, which they can change in Settings while the
    /// app is away, and the library's changes once the app may read it.
    private static func observe() {
        guard !observing else { return }
        observing = true
        observeLibrary(HostPhotos.access)
        #if canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { _ in
            let access = currentAccess
            if access != HostPhotos.access {
                // What the app sees has changed with it: the guest looks
                // again.
                HostPhotos.access = access
                observeLibrary(access)
                HostPhotos.libraryChanged()
            }
        }
    }

    /// Hears PhotoKit's changes once there's something to read: an observer
    /// registered before is no use, and may be what asks the user.
    private static func observeLibrary(_ access: PhotoLibraryAccess) {
        guard observer == nil, access.allowsReading, HostPhotos.allowsReading else { return }
        let observer = LibraryObserver()
        Self.observer = observer
        PHPhotoLibrary.shared().register(observer)
    }
}

/// PhotoKit's changes, from any app, a sync or this one.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // On a queue of PhotoKit's.
        DispatchQueue.main.async {
            HostPhotos.libraryChanged()
        }
    }
}

/// Photo library access as the built-in `Permissions` contract reports it.
final class PhotoLibraryPermission: DarwinHost.PermissionProvider {

    func status() -> PermissionStatus {
        PhotoValues.permission(HostPhotos.effectiveAccess, allowsReading: HostPhotos.allowsReading)
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        HostPhotos.requestAccess { completion(PhotoValues.permission($0, allowsReading: HostPhotos.allowsReading)) }
    }
}
