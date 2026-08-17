import Foundation

/// Local, gitignored record of every asset this tool has edited, so
/// `revert-all` and `list` work without re-scanning the whole library.
/// Lives under Application Support -- never inside the repo.
public final class Ledger {
    public let fileURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("ledger.json")
    }

    public func load() -> [LedgerEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LedgerEntry].self, from: data)) ?? []
    }

    public func append(_ entry: LedgerEntry) {
        var entries = load()
        entries.removeAll { $0.assetLocalIdentifier == entry.assetLocalIdentifier }
        entries.append(entry)
        save(entries)
    }

    public func remove(assetLocalIdentifier: String) {
        var entries = load()
        entries.removeAll { $0.assetLocalIdentifier == assetLocalIdentifier }
        save(entries)
    }

    private func save(_ entries: [LedgerEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotosAutoRotate", isDirectory: true)
    }
    public static var reportsDirectory: URL { supportDirectory.appendingPathComponent("reports", isDirectory: true) }
}
