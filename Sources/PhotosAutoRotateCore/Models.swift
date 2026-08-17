import Foundation

/// The four orientations an upright photo can be rotated into, expressed as
/// clockwise degrees needed to bring the image to "correct" upright.
public enum RotationDegrees: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case cw90 = 90
    case cw180 = 180
    case cw270 = 270
}

public struct OrientationScore: Codable, Sendable {
    public let rotation: RotationDegrees
    public let score: Double
    public init(rotation: RotationDegrees, score: Double) {
        self.rotation = rotation
        self.score = score
    }
}

public struct ClassificationResult: Codable, Sendable {
    public let assetLocalIdentifier: String
    public let filename: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scores: [OrientationScore]
    public let bestRotation: RotationDegrees
    public let confidence: Double
    public let signalsUsed: [String]
    public let skippedReason: String?

    public init(assetLocalIdentifier: String, filename: String?, pixelWidth: Int, pixelHeight: Int,
                scores: [OrientationScore], bestRotation: RotationDegrees, confidence: Double,
                signalsUsed: [String], skippedReason: String? = nil) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scores = scores
        self.bestRotation = bestRotation
        self.confidence = confidence
        self.signalsUsed = signalsUsed
        self.skippedReason = skippedReason
    }

    public var needsRotation: Bool { skippedReason == nil && bestRotation != .none }
}

public struct ScanReport: Codable {
    public let generatedAt: String
    public let libraryAssetCount: Int
    public let classified: [ClassificationResult]
    public let skippedCount: Int
    public init(generatedAt: String, libraryAssetCount: Int, classified: [ClassificationResult], skippedCount: Int) {
        self.generatedAt = generatedAt; self.libraryAssetCount = libraryAssetCount
        self.classified = classified; self.skippedCount = skippedCount
    }
}

/// Adjustment payload we stamp into PHAdjustmentData so applied edits are
/// identifiable and precisely revertible later.
public struct AutoRotateAdjustment: Codable {
    public static let formatIdentifier = "org.batesai.photos-autorotate"
    public static let formatVersion = "1"

    public let degrees: Int
    public let confidence: Double
    public let appliedAt: String
    public init(degrees: Int, confidence: Double, appliedAt: String) {
        self.degrees = degrees; self.confidence = confidence; self.appliedAt = appliedAt
    }
}

/// One entry in the local ledger of assets this tool has edited, so `revert-all`
/// can find them without re-scanning the whole library.
public struct LedgerEntry: Codable {
    public let assetLocalIdentifier: String
    public let degrees: Int
    public let confidence: Double
    public let appliedAt: String
    public init(assetLocalIdentifier: String, degrees: Int, confidence: Double, appliedAt: String) {
        self.assetLocalIdentifier = assetLocalIdentifier; self.degrees = degrees
        self.confidence = confidence; self.appliedAt = appliedAt
    }
}
