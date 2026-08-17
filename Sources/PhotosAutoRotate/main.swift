import Foundation
import Photos
import Vision
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

    case "status":
        // Debug: PhotoKit's view of an asset (adjustments, size, our ledger flag).
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        guard let id = options["_positional"] else { print("Usage: photos-autorotate status <asset-local-identifier>"); exit(1) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let a = assets.firstObject else { print("not found"); exit(1) }
        let own = await PhotoKitRotator().hasOwnAdjustment(assetID: id)
        print("\(id): subtypes=\(a.mediaSubtypes.rawValue) burst=\(a.burstIdentifier ?? "-") src=\(a.sourceType.rawValue) canEdit=\(a.canPerform(.content)) \(a.pixelWidth)x\(a.pixelHeight) hasAdjustments=\(a.hasAdjustments) ourAdjustment=\(own) modified=\(a.modificationDate.map { "\($0)" } ?? "-")")

    case "rotate":
        // Debug: force-rotate one asset (bypasses classifier). Ledgered, revertible.
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        let parts = (options["_positional"] ?? "").split(separator: " ").map(String.init)
        guard parts.count == 2, let deg = Int(parts[1]), let rot = RotationDegrees(rawValue: deg) else { print("Usage: photos-autorotate rotate <id> <90|180|270>"); exit(1) }
        do {
            _ = try await PhotoKitRotator().rotate(assetID: parts[0], degrees: rot, confidence: 0)
            ledger.append(LedgerEntry(assetLocalIdentifier: parts[0], degrees: deg, confidence: 0, appliedAt: ISO8601DateFormatter().string(from: Date())))
            print("rotated \(parts[0]) by \(deg)°")
        } catch { print("ERROR: \(error)"); exit(1) }

    case "review-album":
        // Builds a Photos album (default "AutoRotate Review") containing the assets the
        // latest scan report would rotate -- assets are NOT modified -- and writes
        // before/after JPEG previews to --out (default ~/Downloads/AutoRotate-Review).
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        let albumName = options["album"] ?? "AutoRotate Review"
        let outDir = URL(fileURLWithPath: options["out"] ?? (NSHomeDirectory() + "/Downloads/AutoRotate-Review"))
        let reportsDir = AppPaths.reportsDirectory
        let reports = ((try? FileManager.default.contentsOfDirectory(atPath: reportsDir.path)) ?? []).filter { $0.hasPrefix("scan-") && $0.hasSuffix(".json") }.sorted()
        guard let latest = reports.last, let data = try? Data(contentsOf: reportsDir.appendingPathComponent(latest)),
              let report = try? JSONDecoder().decode(ScanReport.self, from: data) else { print("ERROR: no scan report found; run scan first."); exit(1) }
        let minConf = options["min-confidence"].flatMap(Double.init) ?? 0.99
        let picks = report.classified.filter { $0.bestRotation != .none && $0.confidence >= minConf }
        print("Report \(latest): \(picks.count) asset(s) would be rotated at >= \(minConf).")
        guard !picks.isEmpty else { print("Nothing to show."); break }
        let ids = picks.map { $0.assetLocalIdentifier }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [PHAsset] = []; assets.enumerateObjects { a, _, _ in list.append(a) }
        // Album: reuse if it exists, else create.
        var album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).objects(at: IndexSet(integersIn: 0..<PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).count)).first { $0.localizedTitle == albumName }
        do {
            if album == nil {
                var placeholder: PHObjectPlaceholder?
                try await PHPhotoLibrary.shared().performChanges { placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName).placeholderForCreatedAssetCollection }
                if let id = placeholder?.localIdentifier { album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject }
            }
            guard let album else { print("ERROR: could not create album"); exit(1) }
            try await PHPhotoLibrary.shared().performChanges { PHAssetCollectionChangeRequest(for: album)?.addAssets(list as NSFastEnumeration) }
            print("Album \"\(albumName)\": added \(list.count) asset(s). Library assets untouched.")
        } catch { print("ERROR: \(error)"); exit(1) }
        // Before/after previews.
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scanner = LibraryScanner()
        var idx = 0
        for a in list {
            idx += 1
            guard let cg = await scanner.requestClassificationImage(for: a, targetSize: 1024) else { continue }
            let r = picks.first { $0.assetLocalIdentifier == a.localIdentifier }!
            let name = String(format: "%03d_%@_rot%d_conf%.4f", idx, String(a.localIdentifier.prefix(8)), r.bestRotation.rawValue, r.confidence)
            writeJPEG(cg, to: outDir.appendingPathComponent(name + "_before.jpg"))
            if let rot = rotateCGImage(cg, cwDegrees: r.bestRotation.rawValue) { writeJPEG(rot, to: outDir.appendingPathComponent(name + "_after.jpg")) }
        }
        print("Previews: \(outDir.path)")

    case "bench-setup":
        // Clears --album, picks --n photos that contain people/animals/buildings
        // (Vision), are editable (user library, no adjustments, not HDR gain-map,
        // not Live), adds them to the album, applies a random known rotation to
        // each (ledgered, revertible) and saves the truth table.
        guard await PhotoKitRotator.requestAuthorization() else { print("ERROR: not authorized."); exit(1) }
        let albumName = options["album"] ?? "AutoRotate Review"
        let n = options["n"].flatMap(Int.init) ?? 100
        var rng = SeededGenerator(seed: UInt64(options["seed"].flatMap(Int.init) ?? 42))
        guard let album = LibraryScanner.album(named: albumName) else { print("ERROR: album \(albumName) not found"); exit(1) }
        // 1. clear
        let existing = PHAsset.fetchAssets(in: album, options: nil)
        if existing.count > 0 {
            try? await PHPhotoLibrary.shared().performChanges { PHAssetCollectionChangeRequest(for: album)?.removeAssets(existing) }
            print("Cleared \(existing.count) asset(s) from \"\(albumName)\".")
        }
        // 2. candidates
        let scanner = LibraryScanner()
        var pool = scanner.fetchEligibleAssets().filter { a in
            a.sourceType == .typeUserLibrary && !a.hasAdjustments && !LibraryScanner.isHDRGainMap(a)
                && !a.mediaSubtypes.contains(.photoDepthEffect) && a.pixelWidth >= 800 && a.pixelHeight >= 800
        }
        pool.shuffle(using: &rng)
        print("\(pool.count) editable candidates; looking for \(n) with people/animals/buildings...")
        let rotator = PhotoKitRotator()
        var picked: [(PHAsset, Int, String)] = []
        var truth: [String: [String: Any]] = [:]
        for a in pool {
            if picked.count >= n { break }
            guard let cg = await scanner.requestClassificationImage(for: a) else { continue }
            guard let why = subjectTag(cg) else { continue }
            let deg = [0, 90, 180, 270].randomElement(using: &rng)!
            if deg != 0 {
                do { try await rotator.rotate(assetID: a.localIdentifier, degrees: RotationDegrees(rawValue: deg)!, confidence: 0) }
                catch { print("  skip \(a.localIdentifier.prefix(8)): rotate failed \(error)"); continue }
                ledger.append(LedgerEntry(assetLocalIdentifier: a.localIdentifier, degrees: deg, confidence: 0, appliedAt: ISO8601DateFormatter().string(from: Date())))
            }
            picked.append((a, deg, why))
            truth[a.localIdentifier] = ["scrambledCW": deg, "subject": why]
            print("  [\(picked.count)/\(n)] \(a.localIdentifier.prefix(8)) \(why) scrambled \(deg)°")
        }
        try? await PHPhotoLibrary.shared().performChanges { PHAssetCollectionChangeRequest(for: album)?.addAssets(picked.map { $0.0 } as NSFastEnumeration) }
        let truthURL = AppPaths.supportDirectory.appendingPathComponent("bench-truth.json")
        try? JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys]).write(to: truthURL)
        print("Album \"\(albumName)\": \(picked.count) photos, truth at \(truthURL.path)")

    case "bench-score":
        // Compares net rotation we applied to each bench asset against the
        // scramble. correct = (scrambled + our corrections) % 360 == 0.
        let truthURL = AppPaths.supportDirectory.appendingPathComponent("bench-truth.json")
        guard let d = try? Data(contentsOf: truthURL), let truth = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { print("no bench-truth.json"); exit(1) }
        let entries = ledger.load()
        var acted = 0, correct = 0, wrong = 0, missed = 0, untouchedOK = 0
        var wrongList: [String] = []
        for (id, t) in truth.sorted(by: { $0.key < $1.key }) {
            let scr = t["scrambledCW"] as? Int ?? 0
            let ours = entries.filter { $0.assetLocalIdentifier == id }
            let fixes = ours.filter { $0.confidence > 0 }        // apply-made entries (bench scramble has confidence 0)
            let net = (scr + fixes.reduce(0) { $0 + $1.degrees }) % 360
            if fixes.isEmpty { if scr == 0 { untouchedOK += 1 } else { missed += 1 } ; continue }
            acted += 1
            if net == 0 { correct += 1 } else { wrong += 1; wrongList.append("\(id.prefix(8)) scrambled \(scr) fixes \(fixes.map { $0.degrees }) net \(net)") }
        }
        let n = truth.count
        print("bench: n=\(n) acted=\(acted) correct=\(correct) wrong=\(wrong) missed(skipped-but-needed)=\(missed) untouched-correct=\(untouchedOK)")
        print(String(format: "precision (of actions) = %.4f   pass criterion >= 0.99 : %@", acted > 0 ? Double(correct)/Double(acted) : 0, (acted > 0 && Double(correct)/Double(acted) >= 0.99) ? "PASS" : "FAIL"))
        print(String(format: "recall (needed fixes made) = %.4f", (missed + correct + wrong) > 0 ? Double(correct)/Double(missed + correct + wrong) : 0))
        for w in wrongList { print("  WRONG: \(w)") }

    case "scan":
        guard await PhotoKitRotator.requestAuthorization() else {
            print("ERROR: Photos access not authorized. Grant access in System Settings > Privacy & Security > Photos.")
            exit(1)
        }
        let limit = options["limit"].flatMap { Int($0) }
        let modelPath = options["model"].map { URL(fileURLWithPath: $0) } ?? defaultModelURL()
        await runScan(limit: limit, modelURL: modelPath, ledger: ledger, writeReport: true, album: options["album"].flatMap(LibraryScanner.album(named:)))

    case "apply":
        guard await PhotoKitRotator.requestAuthorization() else {
            print("ERROR: Photos access not authorized. Grant access in System Settings > Privacy & Security > Photos.")
            exit(1)
        }
        let limit = options["limit"].flatMap { Int($0) }
        let minConfidence = options["min-confidence"].flatMap { Double($0) } ?? 0.99
        let modelPath = options["model"].map { URL(fileURLWithPath: $0) } ?? defaultModelURL()
        let autoYes = flags.contains("yes")
        await runApply(limit: limit, minConfidence: minConfidence, modelURL: modelPath, ledger: ledger, autoYes: autoYes, album: options["album"].flatMap(LibraryScanner.album(named:)))

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

func classifyLibrary(limit: Int?, modelURL: URL, album: PHAssetCollection? = nil) async -> [ClassificationResult] {
    let scanner = LibraryScanner()
    let visionClassifier = VisionOrientationClassifier()
    let coreMLClassifier = CoreMLOrientationClassifier(modelURL: modelURL)
    let engine = DecisionEngine()

    if !coreMLClassifier.isAvailable {
        print("WARNING: CoreML model not found at \(modelURL.path). Falling back to Vision-only heuristic, which will skip almost everything by design. See docs/DESIGN.md.")
    }

    let assets = scanner.fetchEligibleAssets(limit: limit, inAlbum: album)
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

func runScan(limit: Int?, modelURL: URL, ledger: Ledger, writeReport: Bool, album: PHAssetCollection? = nil) async {
    let results = await classifyLibrary(limit: limit, modelURL: modelURL, album: album)
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

func runApply(limit: Int?, minConfidence: Double, modelURL: URL, ledger: Ledger, autoYes: Bool, album: PHAssetCollection? = nil) async {
    let results = await classifyLibrary(limit: limit, modelURL: modelURL, album: album)
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


func writeJPEG(_ cg: CGImage, to url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary); CGImageDestinationFinalize(d)
}

func rotateCGImage(_ cg: CGImage, cwDegrees: Int) -> CGImage? {
    let k = ((cwDegrees / 90) % 4 + 4) % 4
    let (w, h) = k % 2 == 0 ? (cg.width, cg.height) : (cg.height, cg.width)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    ctx.rotate(by: -CGFloat(k) * .pi / 2)
    ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
    return ctx.makeImage()
}


/// Deterministic RNG so bench runs are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
}

/// Returns a short tag if the image clearly contains a person, an animal, or a
/// building/structure (Vision), else nil. Used to pick unambiguous bench photos.
func subjectTag(_ cg: CGImage) -> String? {
    let faces = VNDetectFaceRectanglesRequest()
    let humans = VNDetectHumanRectanglesRequest()
    let animals = VNRecognizeAnimalsRequest()
    let scene = VNClassifyImageRequest()
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    try? h.perform([faces, humans, animals, scene])
    if let f = faces.results, f.contains(where: { $0.confidence > 0.9 }) { return "face" }
    if let hu = humans.results, hu.contains(where: { $0.confidence > 0.9 }) { return "person" }
    if let an = animals.results, an.contains(where: { $0.confidence > 0.8 }) { return "animal" }
    let buildingWords = ["building", "house", "church", "skyscraper", "castle", "architecture", "tower", "bridge", "cityscape", "street", "temple", "cathedral", "barn", "lighthouse", "stadium"]
    if let obs = scene.results {
        for o in obs where o.confidence > 0.6 {
            if buildingWords.contains(where: { o.identifier.lowercased().contains($0) }) { return "building:" + o.identifier }
        }
    }
    return nil
}
