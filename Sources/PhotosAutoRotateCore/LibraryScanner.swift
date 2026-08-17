import ImageIO
import Foundation
import Photos
import CoreGraphics
import AppKit

public struct ScanCandidate {
    public let asset: PHAsset
    public let cgImage: CGImage
}

/// Enumerates the user's Photos library and hands back a full-resolution
/// (but memory-capped) CGImage for each eligible photo. Videos, Live Photos,
/// and already-edited assets are skipped -- this tool only ever touches
/// plain still photos it has not already processed.
/// Resume a continuation at most once (first of: result callback, timeout).
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock(); private var cont: CheckedContinuation<T?, Never>?
    func set(_ c: CheckedContinuation<T?, Never>) { lock.lock(); cont = c; lock.unlock() }
    func resume(_ v: T?) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
}

/// Await `body`'s continuation, but give up with nil after `seconds`.
func withTimeout<T>(_ seconds: Double, _ body: (Once<T>) -> Void) async -> T? {
    let once = Once<T>()
    let timer = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); once.resume(nil) }
    let v: T? = await withCheckedContinuation { cont in once.set(cont); body(once) }
    timer.cancel()
    return v
}

public final class LibraryScanner {
    public init() {}

    public func fetchEligibleAssets(limit: Int? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, stop in
            // Skip Live Photos (rotating just the still would desync the video component)
            // and RAW/panorama/screenshot subtypes where "correct orientation" is ambiguous
            // or the pixel data path differs from a plain JPEG/HEIC.
            let subtypes = asset.mediaSubtypes
            if subtypes.contains(.photoLive) || subtypes.contains(.photoPanorama) || subtypes.contains(.photoScreenshot) {
                return
            }
            assets.append(asset)
            if let limit, assets.count >= limit { stop.pointee = true }
        }
        return assets
    }

    /// Loads a downscaled-but-classification-quality CGImage for `asset`.
    /// Uses PHImageManager rather than PHContentEditingInput because scanning
    /// should never trigger a full-size iCloud download for every photo in
    /// the library -- only `apply` does that, and only for assets that pass
    /// the confidence threshold.
    /// Fetch a downscaled (~targetSize px) copy of the asset as Photos displays
    /// it (EXIF + edits applied). Primary path: PHImageManager.requestImage,
    /// which serves cached derivatives and, for iCloud-only assets, a
    /// downscaled derivative rather than the full original. Fallback: read the
    /// local original data (never over the network) and decode a thumbnail.
    /// Times out rather than hanging on a stalled iCloud fetch.
    public func requestClassificationImage(for asset: PHAsset, targetSize: CGFloat = 768,
                                           allowNetwork: Bool = true, timeoutSeconds: Double = 20) async -> CGImage? {
        if ProcessInfo.processInfo.environment["PAR_FORCE_DATA"] == nil,
           let cg = await requestViaImageManager(asset, targetSize: targetSize, allowNetwork: allowNetwork, timeout: timeoutSeconds) {
            Self.dump(cg, name: "reqimg-\(asset.localIdentifier.prefix(8))")
            return cg
        }
        let data: Data? = await withTimeout(timeoutSeconds) { (once: Once<Data>) in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in once.resume(data) }
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation as Photos displays it
            kCGImageSourceThumbnailMaxPixelSize: Int(targetSize),
        ]
        let out = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        Self.dump(out, name: "data-\(asset.localIdentifier.prefix(8))")
        return out
    }

    private func requestViaImageManager(_ asset: PHAsset, targetSize: CGFloat, allowNetwork: Bool, timeout: Double) async -> CGImage? {
        let img: NSImage? = await withTimeout(timeout) { (once: Once<NSImage>) in
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = allowNetwork
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: targetSize, height: targetSize),
                                                  contentMode: .aspectFit, options: o) { im, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }   // wait for the final callback
                once.resume(im)
            }
        }
        return img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func dump(_ cg: CGImage?, name: String) {
        guard let cg, let dir = ProcessInfo.processInfo.environment["PAR_DUMP"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
    }
}
