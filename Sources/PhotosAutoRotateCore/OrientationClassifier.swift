import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Local, offline, no-network orientation classifier.
///
/// Apple ships no "detect image orientation" API, so this uses a heuristic:
/// run face detection and text recognition on the same image at all four
/// candidate orientations (Vision's detectors assume upright input) and pick
/// the orientation that produces the strongest / most confident detections.
/// This is deliberately conservative — when no faces or text are found in
/// any orientation, confidence is 0 and the caller should skip the asset
/// rather than guess.
public final class VisionOrientationClassifier {
    public init() {}

    private static let candidateOrientations: [(RotationDegrees, CGImagePropertyOrientation)] = [
        (.none, .up),
        (.cw90, .right),
        (.cw180, .down),
        (.cw270, .left),
    ]

    public func classify(cgImage: CGImage) -> (scores: [OrientationScore], signalsUsed: [String]) {
        var scores: [RotationDegrees: Double] = [:]
        var signals: Set<String> = []

        for (rotation, orientation) in Self.candidateOrientations {
            var score = 0.0

            let faceRequest = VNDetectFaceRectanglesRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try? handler.perform([faceRequest, textRequest])

            if let faces = faceRequest.results {
                for face in faces {
                    // Upright, high-confidence, roll-near-zero faces score highest.
                    var faceScore = Double(face.confidence)
                    if let roll = face.roll?.doubleValue {
                        let rollDegrees = abs(roll * 180 / .pi)
                        // Penalize faces that are themselves tilted a lot even in
                        // this candidate orientation -- a well-oriented image
                        // should produce roll close to 0.
                        faceScore *= max(0, 1 - rollDegrees / 90)
                    }
                    score += faceScore * 3.0
                    if faceScore > 0 { signals.insert("face") }
                }
            }

            if let textObservations = textRequest.results {
                for obs in textObservations {
                    if let candidate = obs.topCandidates(1).first {
                        score += Double(candidate.confidence) * 1.0
                        signals.insert("text")
                    }
                }
            }

            scores[rotation] = score
        }

        let ordered = Self.candidateOrientations.map { OrientationScore(rotation: $0.0, score: scores[$0.0] ?? 0) }
        return (ordered, Array(signals).sorted())
    }

    /// Combines raw scores into a best rotation + confidence in [0,1].
    /// Confidence is the winning score's share of total score across all
    /// four orientations; if total score is 0 (no signals found at all),
    /// confidence is 0 and callers should treat the asset as "unknown".
    public func bestGuess(from scores: [OrientationScore]) -> (rotation: RotationDegrees, confidence: Double) {
        let total = scores.reduce(0.0) { $0 + $1.score }
        guard total > 0, let winner = scores.max(by: { $0.score < $1.score }) else {
            return (.none, 0)
        }
        return (winner.rotation, winner.score / total)
    }
}
