import Foundation
import CoreML
import CoreImage
import CoreGraphics
import Vision

/// Wraps the bundled CoreML orientation model (EfficientNetV2-S, fine-tuned
/// on ~756k rotated-image samples, 98.82% validation accuracy -- converted
/// from https://github.com/duartebarbosadev/deep-image-orientation-detection,
/// MIT licensed). This is the primary, high-precision classifier; the
/// Vision-heuristic classifier is used as an independent cross-check because
/// validation accuracy on a curated dataset does not guarantee 99% accuracy
/// on any one user's real photo library.
///
/// Class index -> corrective clockwise rotation, per the source repo's
/// CLASS_MAP: 0 -> 0°, 1 -> 90°, 2 -> 180°, 3 -> 270°.
public final class CoreMLOrientationClassifier {
    private let model: MLModel?
    private let inputName: String
    private let outputName: String
    public static let imageSize = 384

    public init(modelURL: URL?) {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            self.model = nil
            self.inputName = ""
            self.outputName = ""
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        // .mlpackage must be compiled to .mlmodelc first; cache next to the package.
        var url = modelURL
        if modelURL.pathExtension == "mlpackage" {
            let compiled = modelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path),
               let tmp = try? MLModel.compileModel(at: modelURL) {
                try? FileManager.default.moveItem(at: tmp, to: compiled)
            }
            url = compiled
        }
        self.model = try? MLModel(contentsOf: url, configuration: config)
        self.inputName = self.model?.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        self.outputName = self.model?.modelDescription.outputDescriptionsByName.keys.first ?? "output"
    }

    public var isAvailable: Bool { model != nil }

    /// Returns per-class probabilities [p(0°), p(90°), p(180°), p(270°)], or
    /// nil if the model isn't loaded / inference failed.
    public func classify(cgImage: CGImage) -> [Double]? { classify(cgImage: cgImage, preRotateCWQuarterTurns: 0) }

    /// The checkpoint was trained with label_smoothing=0.1, so a perfectly
    /// confident prediction saturates at ~0.925 (0.9 + 0.1/4), never 1.0.
    /// Divide by that ceiling so downstream thresholds like 0.99 are meaningful.
    public static let labelSmoothingCeiling = 0.925

    /// Test-time-augmentation consensus: classify the image at 0/90/180/270
    /// additional CW rotations. Each view must predict a correction that maps
    /// back to the SAME underlying correction (rotating the input by k quarter
    /// turns CW shifts the predicted class by -k). If any view disagrees the
    /// image is ambiguous and we return nil (=> skip). Otherwise return a
    /// 4-vector whose winning entry is the MIN calibrated probability across
    /// the four views (the weakest link), the rest split evenly.
    public func classifyConsensus(cgImage: CGImage, useFlips: Bool = true) -> [Double]? {
        var aligned: Int? = nil
        var minP = 1.0
        for flip in (useFlips ? [false, true] : [false]) {
            for k in 0..<4 {
                guard let probs = classify(cgImage: cgImage, preRotateCWQuarterTurns: k, mirrored: flip), probs.count == 4 else { return nil }
                let c = probs.indices.max { probs[$0] < probs[$1] }!
                // View = mirror(rotate_k(image)) (CG applies the CTM ops set first
                // last to the drawn content). rotate_k shifts the needed correction
                // by -k; a horizontal mirror negates it (90<->270). So:
                //   unflipped: c = r - k  => r = c + k
                //   flipped:   c = k - r  => r = k - c
                let r = flip ? ((k - c) % 4 + 4) % 4 : (c + k) % 4
                if let a = aligned, a != r { return nil }
                aligned = r
                minP = min(minP, min(1.0, probs[c] / Self.labelSmoothingCeiling))
            }
        }
        guard let r = aligned else { return nil }
        var out = [Double](repeating: (1 - minP) / 3, count: 4)
        out[r] = minP
        return out
    }

    public func classify(cgImage: CGImage, preRotateCWQuarterTurns k: Int, mirrored: Bool = false) -> [Double]? {
        guard let model else { return nil }
        let size = Self.imageSize
        guard let pixelBuffer = Self.makePixelBuffer(from: cgImage, size: size, cwQuarterTurns: k, mirrored: mirrored) else { return nil }
        guard let featureValue = try? MLFeatureValue(pixelBuffer: pixelBuffer) as MLFeatureValue? else { return nil }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: featureValue]) else { return nil }
        guard let result = try? model.prediction(from: provider) else { return nil }
        guard let out = result.featureValue(for: outputName)?.multiArrayValue else { return nil }
        var probs = [Double](repeating: 0, count: out.count)
        for i in 0..<out.count { probs[i] = out[i].doubleValue }
        return probs
    }

    private static func makePixelBuffer(from cgImage: CGImage, size: Int, cwQuarterTurns k: Int = 0, mirrored: Bool = false) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                       kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        // Resize with aspect-fill + center-crop to match the model's
        // Resize(size+32) -> CenterCrop(size) preprocessing.
        let srcW = CGFloat(cgImage.width), srcH = CGFloat(cgImage.height)
        let scale = max(CGFloat(size) / srcW, CGFloat(size) / srcH)
        let scaledW = srcW * scale, scaledH = srcH * scale
        let x = (CGFloat(size) - scaledW) / 2, y = (CGFloat(size) - scaledH) / 2
        context.interpolationQuality = .high
        if mirrored {
            // Horizontal flip about the canvas center (applied before rotation).
            context.translateBy(x: CGFloat(size), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if k % 4 != 0 {
            // CG's coordinate space is y-up; rotating by -k*90° in that space
            // yields a k*90° clockwise rotation as seen on screen.
            let c = CGFloat(size) / 2
            context.translateBy(x: c, y: c)
            context.rotate(by: -CGFloat(k % 4) * .pi / 2)
            context.translateBy(x: -c, y: -c)
        }
        // The aspect-fill rect is centered on the canvas, so rotating about the
        // center keeps it centered; the corners that leave the canvas were crop anyway.
        context.draw(cgImage, in: CGRect(x: x, y: y, width: scaledW, height: scaledH))
        return buffer
    }
}
