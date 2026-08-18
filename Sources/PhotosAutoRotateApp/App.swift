import SwiftUI
import Photos
import PhotosAutoRotateCore

@main
struct PhotosAutoRotateApp: App {
    @StateObject private var vm = Engine()
    var body: some Scene {
        WindowGroup("Photos AutoRotate") {
            ContentView().environmentObject(vm).frame(minWidth: 640, minHeight: 460)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var vm: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "rotate.right").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Photos AutoRotate").font(.title2).bold()
                    Text("Finds sideways / upside-down photos and fixes them — only when it is ≥99% sure. Every fix is a normal Photos edit (Revert to Original works).").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("Scope", selection: $vm.scope) { Text("Whole library").tag(""); ForEach(vm.albums, id: \.self) { Text("Album: \($0)").tag($0) } }.frame(maxWidth: 360)
                Spacer()
                Toggle("Dry run (report only)", isOn: $vm.dryRun)
            }
            HStack(spacing: 10) {
                Button(vm.dryRun ? "Scan" : "Scan & Fix") { vm.run() }.keyboardShortcut(.defaultAction).disabled(vm.busy)
                Button("Revert everything this app changed") { vm.revertAll() }.disabled(vm.busy || vm.ledgerCount == 0)
                if vm.busy { ProgressView().controlSize(.small); Button("Stop") { vm.cancel = true } }
                Spacer()
                Text("\(vm.ledgerCount) fixes on record").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: vm.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                Text(vm.status).font(.footnote).foregroundStyle(.secondary); Spacer()
                Button("Open Reports Folder") { NSWorkspace.shared.open(AppPaths.reportsDirectory) }.font(.footnote)
            }
        }
        .padding(16)
        .task { await vm.bootstrap() }
    }
}

@MainActor
final class Engine: ObservableObject {
    @Published var log = ""; @Published var status = "Ready."; @Published var busy = false
    @Published var dryRun = true; @Published var scope = ""; @Published var albums: [String] = []
    @Published var ledgerCount = 0
    var cancel = false
    let ledger = Ledger(directory: AppPaths.supportDirectory)
    let minConfidence = 0.99

    func bootstrap() async {
        let ok = await PhotoKitRotator.requestAuthorization()
        if !ok { status = "Photos access denied — allow it in System Settings ▸ Privacy & Security ▸ Photos, then relaunch."; return }
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var names: [String] = []; cols.enumerateObjects { c, _, _ in if let t = c.localizedTitle { names.append(t) } }
        albums = names.sorted(); ledgerCount = ledger.load().count
        status = "Photos access OK. \(albums.count) albums."
    }

    func append(_ s: String) { log += s + "\n" }

    func run() {
        busy = true; cancel = false; log = ""
        let dry = dryRun, scopeName = scope
        Task {
            defer { busy = false; ledgerCount = ledger.load().count }
            guard let modelURL = Bundle.main.url(forResource: "OrientationClassifier", withExtension: "mlpackage") else { append("ERROR: model missing from app bundle"); return }
            let a = CoreMLOrientationClassifier(modelURL: modelURL)
            let bURL = Bundle.main.url(forResource: "OrientationClassifierB", withExtension: "mlpackage")
            let b = bURL.map { CoreMLOrientationClassifier(modelURL: $0, imageSize: 224, calibrationCeiling: 1.0) }
            guard a.isAvailable else { append("ERROR: could not load model"); return }
            let scanner = LibraryScanner(); let engine = DecisionEngine(); let vision = VisionOrientationClassifier(); let rotator = PhotoKitRotator()
            let album = scopeName.isEmpty ? nil : LibraryScanner.album(named: scopeName)
            let assets = scanner.fetchEligibleAssets(inAlbum: album)
            append("\(assets.count) eligible photos in \(scopeName.isEmpty ? "library" : "album \"\(scopeName)\"") (videos, Live Photos, panoramas, screenshots skipped).")
            var fixed = 0, flagged = 0, failed = 0, done = 0, unreadable = 0
            var results: [ClassificationResult] = []
            for asset in assets {
                if cancel { append("Stopped by user."); break }
                done += 1
                if done % 25 == 0 { status = "\(done)/\(assets.count) checked · \(flagged) need rotation · \(fixed) fixed" }
                guard let cg = await scanner.requestClassificationImage(for: asset) else { unreadable += 1; continue }
                let pa = a.classifyConsensus(cgImage: cg)
                let pb = (b?.isAvailable ?? false) ? b!.classifyConsensus(cgImage: cg) : nil
                let (vs, _) = vision.classify(cgImage: cg)
                let d = engine.decide(coreMLProbs: pa, modelBProbs: pb, visionScores: vs, visionClassifier: vision)
                results.append(ClassificationResult(assetLocalIdentifier: asset.localIdentifier, filename: asset.value(forKey: "filename") as? String,
                                                    pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, scores: vs, bestRotation: d.rotation,
                                                    confidence: d.confidence, signalsUsed: [], skippedReason: d.rotation == .none ? d.reason : nil))
                guard d.rotation != .none, d.confidence >= minConfidence else { continue }
                flagged += 1
                let name = (asset.value(forKey: "filename") as? String) ?? String(asset.localIdentifier.prefix(8))
                if dry { append("would rotate \(name) by \(d.rotation.rawValue)° (\(String(format: "%.3f", d.confidence)))"); continue }
                do {
                    _ = try await rotator.rotate(assetID: asset.localIdentifier, degrees: d.rotation, confidence: d.confidence)
                    ledger.append(LedgerEntry(assetLocalIdentifier: asset.localIdentifier, degrees: d.rotation.rawValue, confidence: d.confidence, appliedAt: ISO8601DateFormatter().string(from: Date())))
                    fixed += 1; append("fixed \(name): rotated \(d.rotation.rawValue)° (\(String(format: "%.3f", d.confidence)))")
                } catch { failed += 1; append("FAILED \(name): \(error)") }
            }
            let report = ScanReport(generatedAt: ISO8601DateFormatter().string(from: Date()), libraryAssetCount: results.count, classified: results, skippedCount: results.count - flagged)
            try? FileManager.default.createDirectory(at: AppPaths.reportsDirectory, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(report) { try? data.write(to: AppPaths.reportsDirectory.appendingPathComponent("scan-\(Int(Date().timeIntervalSince1970)).json")) }
            append("Done. \(done) checked, \(flagged) needed rotation" + (dry ? " (dry run — nothing changed)." : ", \(fixed) fixed, \(failed) failed.") + (unreadable > 0 ? " \(unreadable) could not be loaded (offline iCloud?)." : ""))
            status = "Done."
        }
    }

    func revertAll() {
        busy = true
        Task {
            defer { busy = false; ledgerCount = ledger.load().count }
            let entries = ledger.load(); let rotator = PhotoKitRotator(); var n = 0
            for e in entries { do { try await rotator.revert(assetID: e.assetLocalIdentifier); ledger.remove(assetLocalIdentifier: e.assetLocalIdentifier); n += 1 } catch { append("revert failed \(e.assetLocalIdentifier.prefix(8)): \(error)") } }
            append("Reverted \(n)/\(entries.count).")
        }
    }
}
