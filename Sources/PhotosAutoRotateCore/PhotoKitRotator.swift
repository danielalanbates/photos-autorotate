import Foundation
import Photos
import CoreImage

public enum RotatorError: Error, CustomStringConvertible {
    case notAuthorized
    case assetNotFound(String)
    case noEditingInput
    case commitFailed(Error?)

    public var description: String {
        switch self {
        case .notAuthorized: return "Photos library access not authorized (read/write)."
        case .assetNotFound(let id): return "Asset not found: \(id)"
        case .noEditingInput: return "Could not obtain editing input for asset."
        case .commitFailed(let e): return "Failed to commit edit: \(e?.localizedDescription ?? "unknown error")"
        }
    }
}

/// Wraps the PhotoKit non-destructive edit path verified against a live
/// Photos library: PHContentEditingInput -> rotate with Core Image ->
/// PHContentEditingOutput -> PHAssetChangeRequest, tagged with
/// AutoRotateAdjustment so it is identifiable and precisely revertible.
public final class PhotoKitRotator {
    public init() {}

    public static func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        return status == .authorized || status == .limited
    }

    private func fetchAsset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw RotatorError.assetNotFound(id)
        }
        return asset
    }

    private func requestEditingInput(_ asset: PHAsset, canHandle: Bool) async throws -> PHContentEditingInput {
        let opts = PHContentEditingInputRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.canHandleAdjustmentData = { _ in canHandle }
        return try await withCheckedThrowingContinuation { cont in
            asset.requestContentEditingInput(with: opts) { input, _ in
                if let input { cont.resume(returning: input) } else { cont.resume(throwing: RotatorError.noEditingInput) }
            }
        }
    }

    /// Rotates `assetID` clockwise by `degrees` (90/180/270) and commits it
    /// as a non-destructive PhotoKit edit. Original pixel data is preserved
    /// by Photos and can be recovered with `revert(assetID:)`.
    @discardableResult
    public func rotate(assetID: String, degrees: RotationDegrees, confidence: Double) async throws -> Bool {
        guard degrees != .none else { return false }
        let asset = try fetchAsset(assetID)
        let input = try await requestEditingInput(asset, canHandle: false)
        guard let sourceURL = input.fullSizeImageURL else { throw RotatorError.noEditingInput }

        let baseOrientation = CGImagePropertyOrientation(rawValue: UInt32(input.fullSizeImageOrientation)) ?? .up
        guard let ci = CIImage(contentsOf: sourceURL) else { throw RotatorError.noEditingInput }
        var rotated = ci.oriented(baseOrientation)
        let steps = degrees.rawValue / 90
        for _ in 0..<steps {
            rotated = rotated.oriented(.right)
        }

        let output = PHContentEditingOutput(contentEditingInput: input)
        let ctx = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw RotatorError.noEditingInput }
        try ctx.writeJPEGRepresentation(of: rotated, to: output.renderedContentURL, colorSpace: colorSpace,
                                         options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])

        let payload = AutoRotateAdjustment(degrees: degrees.rawValue, confidence: confidence, appliedAt: ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(payload)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: AutoRotateAdjustment.formatIdentifier,
                                                  formatVersion: AutoRotateAdjustment.formatVersion,
                                                  data: data)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest(for: asset)
                req.contentEditingOutput = output
            }) { ok, err in
                if ok { cont.resume() } else { cont.resume(throwing: RotatorError.commitFailed(err)) }
            }
        }
        return true
    }

    /// Reverts `assetID` to its original, untouched pixels. Safe to call on
    /// any asset -- if it was never edited this is a no-op.
    public func revert(assetID: String) async throws {
        let asset = try fetchAsset(assetID)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }) { ok, err in
                if ok { cont.resume() } else { cont.resume(throwing: RotatorError.commitFailed(err)) }
            }
        }
    }

    /// True if the asset's current edit was applied by this tool (safe to
    /// revert/re-apply); false if the asset has someone else's edit or none.
    public func hasOwnAdjustment(assetID: String) async -> Bool {
        guard let asset = try? fetchAsset(assetID) else { return false }
        guard asset.hasAdjustments else { return false }
        var found = false
        let opts = PHContentEditingInputRequestOptions()
        opts.canHandleAdjustmentData = { ad in
            found = ad.formatIdentifier == AutoRotateAdjustment.formatIdentifier
            return false
        }
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            asset.requestContentEditingInput(with: opts) { _, _ in cont.resume() }
        }
        return found
    }
}
