import XCTest
@testable import PhotosAutoRotateCore

final class DecisionEngineTests: XCTestCase {
    func testBelowThresholdSkips() {
        let e = DecisionEngine()
        let d = e.decide(coreMLProbs: [0.05, 0.9, 0.03, 0.02], visionScores: nil, visionClassifier: VisionOrientationClassifier())
        XCTAssertEqual(d.rotation, .none)
    }
    func testAboveThresholdRotates() {
        let e = DecisionEngine()
        let d = e.decide(coreMLProbs: [0.001, 0.995, 0.002, 0.002], visionScores: nil, visionClassifier: VisionOrientationClassifier())
        XCTAssertNotEqual(d.rotation, .none)
    }
}
