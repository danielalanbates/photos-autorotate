import Foundation
import Photos
import PhotosAutoRotateCore

func printHelp() {
    print("""
    photos-autorotate -- automatically rotate mis-oriented photos in Apple Photos.

    USAGE:
      photos-autorotate scan  [--limit N] [--model PATH]
          Read-only. Classifies every eligible photo and writes a JSON+text
          report to ~/Library/Application Support/PhotosAutoRotate/reports/.
          Never modifies the library.

      photos-autorotate apply [--limit N] [--min-confidence 0.99] [--model PATH] [--yes]
          Rotates only photos classified above --min-confidence (default
          0.99). Everything else is left untouched. Prompts for confirmation
          unless --yes is passed. Every edit is non-destructive (Photos keeps
          the original; use `revert-all` or Photos' own "Revert to Original").

      photos-autorotate revert-all
          Reverts every asset this tool has edited, using its local ledger.

      photos-autorotate revert <asset-local-identifier>
          Reverts a single asset.

      photos-autorotate list
          Lists assets this tool has edited (from the local ledger).

    NOTES:
      - Requires Photos read/write access (macOS will prompt on first run).
      - Skips videos, Live Photos, panoramas, and screenshots.
      - Default model path: models/OrientationClassifier.mlpackage next to
        this binary, or pass --model explicitly. Without a model, apply
        effectively rotates nothing (Vision-only fallback needs ~99.9%
        heuristic confidence, which real photos essentially never reach) --
        this is intentional; see docs/DESIGN.md.
    """)
}

func parseArgs(_ args: [String]) -> (command: String, options: [String: String], flags: Set<String>) {
    guard let command = args.first else { return ("", [:], []) }
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                options[key] = args[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        } else {
            positional.append(a)
            i += 1
        }
    }
    if !positional.isEmpty { options["_positional"] = positional.joined(separator: " ") }
    return (command, options, flags)
}

func defaultModelURL() -> URL {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    return exeDir.appendingPathComponent("models/OrientationClassifier.mlpackage")
}

func run() async {
    let args = Array(CommandLine.arguments.dropFirst())
    let (command, options, flags) = parseArgs(args)

    guard !command.isEmpty else { printHelp(); return }

    if command == "help" || flags.contains("help") {
        printHelp()
        return
    }

    let ledger = Ledger(directory: AppPaths.supportDirectory)

    switch command {
    case "list":
        let entries = ledger.load()
        if entries.isEmpty {
            print("No assets have been edited by photos-autorotate yet.")
        } else {
            print("\(entries.count) asset(s) edited by photos-autorotate:")
            for e in entries {
                print("  \(e.assetLocalIdentifier)  rotated \(e.degrees)°  confidence \(e.confidence)  at \(e.appliedAt)")
            }
        }

    case "classify-file":
        // Debug/verification: classify image files on disk, no Photos access needed.
        let modelPath = options["model"].map { URL(fileURLWithPath: $0) } ?? defaultModelURL()
        let clf = CoreMLOrientationClassifier(modelURL: modelPath)
        guard clf.isAvailable else { print("ERROR: model not loaded from \(modelPath.path)"); exit(1) }
        let positional = args.dropFirst().filter { !$0.hasPrefix("--") && $0 != options["model"] }
        for path in positional {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary)
            else { print("\(path): could not load"); continue }
            let vis = VisionOrientationClassifier()
            let (vs, sig) = vis.classify(cgImage: cg)
            let vg = vis.bestGuess(from: vs)
            print("  vision: rotate \(vg.rotation.rawValue)° conf \(String(format: "%.2f", vg.confidence)) signals=\(sig) scores=\(vs.map { "\($0.rotation.rawValue):\(String(format: "%.1f", $0.score))" })")
            var views: [String] = []
            for k in 0..<4 {
                let p = clf.classify(cgImage: cg, preRotateCWQuarterTurns: k) ?? []
                let c = p.indices.max { p[$0] < p[$1] } ?? -1
                views.append("view+\(k*90)cw→class \(c) (\(String(format: "%.3f", c >= 0 ? p[c] : 0)))")
            }
            if let cons = clf.classifyConsensus(cgImage: cg) {
                let c = cons.indices.max { cons[$0] < cons[$1] }!
                print("\(path)\n  consensus: rotate \(c*90)° CW, calibrated confidence \(String(format: "%.4f", cons[c]))\n  " + views.joined(separator: "; "))
            } else {
                print("\(path)\n  consensus: NONE (views disagree → skip)\n  " + views.joined(separator: "; "))
            }
        }

    case "scan":
        guard await PhotoKitRotator.requestAuthorization() else {
            print("ERROR: Photos access not authorized. Grant access in System Settings > Privacy & Security > Photos.")
            exit(1)
        }
        let limit = options["limit"].flatMap { Int($0) }
        let modelPath = options["model"].map { URL(fileURLWithPath: $0) } ?? defaultModelURL()
        await runScan(limit: limit, modelURL: modelPath, ledger: ledger, writeReport: true)

    case "apply":
        guard await PhotoKitRotator.requestAuthorization() else {
            print("ERROR: Photos access not authorized. Grant access in System Settings > Privacy & Security > Photos.")
            exit(1)
        }
        let limit = options["limit"].flatMap { Int($0) }
        let minConfidence = options["min-confidence"].flatMap { Double($0) } ?? 0.99
        let modelPath = options["model"].map { URL(fileURLWithPath: $0) } ?? defaultModelURL()
        let autoYes = flags.contains("yes")
        await runApply(limit: limit, minConfidence: minConfidence, modelURL: modelPath, ledger: ledger, autoYes: autoYes)

    case "revert-all":
        let entries = ledger.load()
        guard !entries.isEmpty else { print("Nothing to revert."); return }
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        let rotator = PhotoKitRotator()
        var reverted = 0
        for e in entries {
            do {
                try await rotator.revert(assetID: e.assetLocalIdentifier)
                ledger.remove(assetLocalIdentifier: e.assetLocalIdentifier)
                reverted += 1
            } catch {
                print("  FAILED to revert \(e.assetLocalIdentifier): \(error)")
            }
        }
        print("Reverted \(reverted)/\(entries.count) asset(s).")

    case "revert":
        guard let id = options["_positional"] else { print("Usage: photos-autorotate revert <asset-local-identifier>"); exit(1) }
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        let rotator = PhotoKitRotator()
        do {
            try await rotator.revert(assetID: id)
            ledger.remove(assetLocalIdentifier: id)
            print("Reverted \(id).")
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }

    default:
        print("Unknown command: \(command)\n")
        printHelp()
        exit(1)
    }
}

func classifyLibrary(limit: Int?, modelURL: URL) async -> [ClassificationResult] {
    let scanner = LibraryScanner()
    let visionClassifier = VisionOrientationClassifier()
    let coreMLClassifier = CoreMLOrientationClassifier(modelURL: modelURL)
    let engine = DecisionEngine()

    if !coreMLClassifier.isAvailable {
        print("WARNING: CoreML model not found at \(modelURL.path). Falling back to Vision-only heuristic, which will skip almost everything by design. See docs/DESIGN.md.")
    }

    let assets = scanner.fetchEligibleAssets(limit: limit)
    print("Found \(assets.count) eligible photo(s) (videos, Live Photos, panoramas, screenshots excluded).")

    var results: [ClassificationResult] = []
    var done = 0
    for asset in assets {
        done += 1
        if done % 25 == 0 { print("  classified \(done)/\(assets.count)...") }
        guard let cgImage = await scanner.requestClassificationImage(for: asset) else {
            results.append(ClassificationResult(assetLocalIdentifier: asset.localIdentifier, filename: nil,
                                                  pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                                  scores: [], bestRotation: .none, confidence: 0,
                                                  signalsUsed: [], skippedReason: "could not load image"))
            continue
        }
        let coreMLProbs = coreMLClassifier.classifyConsensus(cgImage: cgImage)
        let (visionScores, signals) = visionClassifier.classify(cgImage: cgImage)
        let decision = engine.decide(coreMLProbs: coreMLProbs, visionScores: visionScores, visionClassifier: visionClassifier)

        results.append(ClassificationResult(
            assetLocalIdentifier: asset.localIdentifier,
            filename: asset.value(forKey: "filename") as? String,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            scores: visionScores,
            bestRotation: decision.rotation,
            confidence: decision.confidence,
            signalsUsed: signals,
            skippedReason: decision.rotation == .none ? decision.reason : nil
        ))
    }
    return results
}

func runScan(limit: Int?, modelURL: URL, ledger: Ledger, writeReport: Bool) async {
    let results = await classifyLibrary(limit: limit, modelURL: modelURL)
    let needsRotation = results.filter { $0.needsRotation }
    print("\nScan complete. \(needsRotation.count)/\(results.count) photo(s) would be rotated at the default 0.99 confidence threshold.")
    for r in needsRotation.prefix(20) {
        print("  \(r.filename ?? r.assetLocalIdentifier): rotate \(r.bestRotation.rawValue)° (confidence \(String(format: "%.4f", r.confidence)))")
    }
    if needsRotation.count > 20 { print("  ... and \(needsRotation.count - 20) more (see full report).") }

    if writeReport {
        let report = ScanReport(generatedAt: ISO8601DateFormatter().string(from: Date()),
                                 libraryAssetCount: results.count, classified: results,
                                 skippedCount: results.count - needsRotation.count)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            let path = AppPaths.reportsDirectory.appendingPathComponent("scan-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.createDirectory(at: AppPaths.reportsDirectory, withIntermediateDirectories: true)
            try? data.write(to: path)
            print("\nFull report written to \(path.path)")
        }
    }
}

func runApply(limit: Int?, minConfidence: Double, modelURL: URL, ledger: Ledger, autoYes: Bool) async {
    let results = await classifyLibrary(limit: limit, modelURL: modelURL)
    let toRotate = results.filter { $0.needsRotation && $0.confidence >= minConfidence }
    guard !toRotate.isEmpty else {
        print("\nNo photos met the \(minConfidence) confidence threshold. Nothing changed.")
        return
    }
    print("\n\(toRotate.count) photo(s) will be rotated (confidence >= \(minConfidence)):")
    for r in toRotate.prefix(20) {
        print("  \(r.filename ?? r.assetLocalIdentifier): rotate \(r.bestRotation.rawValue)° (confidence \(String(format: "%.4f", r.confidence)))")
    }
    if toRotate.count > 20 { print("  ... and \(toRotate.count - 20) more.") }

    if !autoYes {
        print("\nProceed? [y/N] ", terminator: "")
        guard let line = readLine(), line.lowercased() == "y" else { print("Aborted."); return }
    }

    let rotator = PhotoKitRotator()
    var succeeded = 0
    for r in toRotate {
        do {
            try await rotator.rotate(assetID: r.assetLocalIdentifier, degrees: r.bestRotation, confidence: r.confidence)
            ledger.append(LedgerEntry(assetLocalIdentifier: r.assetLocalIdentifier, degrees: r.bestRotation.rawValue,
                                       confidence: r.confidence, appliedAt: ISO8601DateFormatter().string(from: Date())))
            succeeded += 1
        } catch {
            print("  FAILED \(r.assetLocalIdentifier): \(error)")
        }
    }
    print("\nRotated \(succeeded)/\(toRotate.count) photo(s). Originals are preserved -- use `revert-all` or Photos' Revert to Original to undo.")
}

await run()
