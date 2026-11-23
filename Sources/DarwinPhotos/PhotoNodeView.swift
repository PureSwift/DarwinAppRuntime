import DynamicPhotos
import Foundation
import Photos
import RuntimePhotos
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// A `Photo` node (`RenderIR.md`): an asset of the user's library, drawn
/// from PhotoKit's thumbnails at the node's size in pixels.
///
/// It takes the space it's offered, and fills it and crops unless told to
/// fit. PhotoKit's opportunistic delivery gives a small copy first and a
/// better one after. A video is its first frame. An asset the app may not
/// see, or one that's gone, draws nothing.
struct PhotoNodeView: View {

    let identifier: String

    let fill: Bool

    @StateObject private var thumbnail = PhotoThumbnail()

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let request = PhotoThumbnail.Request(
                identifier: identifier,
                width: Int((geometry.size.width * displayScale).rounded(.up)),
                height: Int((geometry.size.height * displayScale).rounded(.up)),
                fill: fill
            )
            picture
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .onAppear { thumbnail.load(request) }
                .onChange(of: request) { thumbnail.load($0) }
        }
        .onDisappear { thumbnail.cancel() }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = thumbnail.image {
            #if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: fill ? .fill : .fit)
            #else
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: fill ? .fill : .fit)
            #endif
        } else {
            Color.clear
        }
    }
}

/// Asks PhotoKit for one node's picture, and replaces it as better copies
/// arrive. Main thread only.
final class PhotoThumbnail: ObservableObject {

    struct Request: Equatable {
        var identifier: String
        var width: Int
        var height: Int
        var fill: Bool
    }

    @Published private(set) var image: PlatformImage?

    /// The system's cache of thumbnails, which every `Photo` shares.
    static let manager = PHCachingImageManager()

    private var current: Request?

    private var requestID: PHImageRequestID?

    func load(_ request: Request) {
        guard request != current else { return }
        let previous = current
        cancel()
        if request.identifier != previous?.identifier {
            // Another asset: the last one's picture isn't this one's.
            image = nil
        }
        current = request
        guard request.width > 0, request.height > 0, HostPhotos.effectiveAccess.allowsReading,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [request.identifier], options: nil).firstObject else {
            image = nil
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = Self.manager.requestImage(
            for: asset,
            targetSize: CGSize(width: request.width, height: request.height),
            contentMode: request.fill ? .aspectFill : .aspectFit,
            options: options
        ) { [weak self] image, _ in
            let apply = {
                guard let self, self.current == request, let image else { return }
                self.image = image
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    func cancel() {
        if let requestID {
            Self.manager.cancelImageRequest(requestID)
        }
        requestID = nil
        current = nil
    }
}
