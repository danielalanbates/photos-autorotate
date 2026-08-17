import Foundation
import CoreGraphics

/// Combines the CoreML classifier (primary, high-accuracy) and the Vision
/// heuristic classifier (independent cross-check) into a single decision,
/// enforcing the project's hard requirement: never rotate a photo unless
/// confidence clears a very high bar, and prefer skipping over guessing.
///
/// Rationale for requiring agreement, not just a high CoreML probability:
/// the model's 98.82% figure is *validation-set* accuracy on curated
/// datasets. A single softmax probability threshold on unseen personal
/// photos (different camera, lighting, subject matter) is not the same
/// guarantee as "99% accurate on this library." Requiring the Vision
/// heuristic (faces/text, a completely different signal) to agree whenever
/// it has an opinion is a cheap, local way to catch the CoreML model's
/// mistakes before they touch the user's library.
public final class DecisionEngine {
    public let minCoreMLConfidence: Double

    /// - Parameters:
    ///   - minCoreMLConfidence: softmax probability required from the CoreML
    ///     model (default 0.99 -- matches the "never rotate unless 99%
    ///     confident" requirement).
    /// Vision only gets to veto CoreML when its own share-of-score is at least
    /// this. Default 1.01 = DISABLED: on the live album bench the face/text
    /// heuristic vetoed correct 0.99+ model calls with wrong answers at 0.7-0.9
    /// confidence, and the 900-trial offline bench had 0 errors with no veto.
    /// Kept as an option for experimentation.
    public let minVisionVetoConfidence: Double

    public init(minCoreMLConfidence: Double = 0.99, minVisionVetoConfidence: Double = 1.01) {
        self.minVisionVetoConfidence = minVisionVetoConfidence
        self.minCoreMLConfidence = minCoreMLConfidence
    }

    private static let classToRotation: [RotationDegrees] = [.none, .cw90, .cw180, .cw270]

    /// Ensemble with an independent second model (B). Thresholds come from a
    /// 1,600-trial offline sweep (docs/DESIGN.md): A>=0.99 alone was 1213/0
    /// wrong; adding "A>=0.75 & B agrees >=0.85" and "A no-consensus & B>=0.95"
    /// took acted 1213->1319 with still 0 wrong (recall 0.75->0.83). The only
    /// wrong agreement seen was A=0.44/B=0.62, far below these floors.
    public var minAForEnsemble = 0.75, minBForEnsemble = 0.85, minBAlone = 0.95

    public func decide(coreMLProbs: [Double]?, modelBProbs: [Double]? = nil, visionScores: [OrientationScore]?, visionClassifier: VisionOrientationClassifier) -> (rotation: RotationDegrees, confidence: Double, reason: String) {
        if let modelBProbs, modelBProbs.count == 4 {
            let bIdx = modelBProbs.indices.max(by: { modelBProbs[$0] < modelBProbs[$1] })!
            let bConf = modelBProbs[bIdx]
            if let a = coreMLProbs, a.count == 4 {
                let aIdx = a.indices.max(by: { a[$0] < a[$1] })!
                if a[aIdx] < minCoreMLConfidence, a[aIdx] >= minAForEnsemble, aIdx == bIdx, bConf >= minBForEnsemble {
                    return (Self.classToRotation[aIdx], min(a[aIdx], bConf), "ensemble: model A \(String(format: "%.3f", a[aIdx])) and independent model B \(String(format: "%.3f", bConf)) agree")
                }
            } else if bConf >= minBAlone {
                return (Self.classToRotation[bIdx], bConf, "ensemble: model A had no consensus, model B \(String(format: "%.3f", bConf))")
            }
        }
        return decideA(coreMLProbs: coreMLProbs, visionScores: visionScores, visionClassifier: visionClassifier)
    }

    private func decideA(coreMLProbs: [Double]?, visionScores: [OrientationScore]?, visionClassifier: VisionOrientationClassifier) -> (rotation: RotationDegrees, confidence: Double, reason: String) {
        let vision = visionScores.map { visionClassifier.bestGuess(from: $0) }

        // No CoreML answer => never act. This covers both "model not loaded"
        // and "the four TTA views disagreed". The Vision heuristic is a veto
        // signal only; it is nowhere near 99% reliable on its own.
        guard let coreMLProbs, coreMLProbs.count == 4 else {
            return (.none, 0, "CoreML gave no consensus (model missing or rotated views disagreed) -- skipping")
        }

        let bestIndex = coreMLProbs.indices.max(by: { coreMLProbs[$0] < coreMLProbs[$1] })!
        let coreMLConfidence = coreMLProbs[bestIndex]
        let coreMLRotation = Self.classToRotation[bestIndex]

        guard coreMLConfidence >= minCoreMLConfidence else {
            return (.none, coreMLConfidence, "CoreML confidence \(coreMLConfidence) below threshold \(minCoreMLConfidence)")
        }

        // If the Vision heuristic has an opinion (found faces or text) and it
        // disagrees with CoreML, refuse to act -- disagreement between two
        // independent signals means we are not actually 99% sure.
        if let vision, vision.confidence >= minVisionVetoConfidence, vision.rotation != coreMLRotation {
            return (.none, min(coreMLConfidence, vision.confidence), "CoreML and Vision heuristic disagree (CoreML=\(coreMLRotation.rawValue)°, Vision=\(vision.rotation.rawValue)°) -- skipping")
        }

        return (coreMLRotation, coreMLConfidence, "CoreML confidence \(coreMLConfidence)" + (vision != nil && vision!.confidence > 0 ? " confirmed by Vision heuristic" : " (Vision heuristic had no opinion)"))
    }
}
