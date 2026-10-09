import Foundation
import SetmioCore

/// Persists incremental-query anchors as a small JSON dictionary (`[key: base64 Data]`) in Application Support.
///
/// Keys are `"<kind.rawValue>#v<schemaVersion>"`: bumping `anchorSchemaVersion` orphans every old anchor, which
/// forces a full re-import after the HealthKit → `HealthSample` mapping changes. Anchors deliberately live
/// outside SwiftData (they are a cache, not user data) and are never synced.
public actor AnchorStore {
    /// Bump when the sample conversion changes in a way that requires re-importing everything.
    public static let anchorSchemaVersion = 1

    public let fileURL: URL
    public let schemaVersion: Int

    private var cache: [String: Data]?
    private let fileManager: FileManager

    public init(
        fileURL: URL = AnchorStore.defaultFileURL(),
        schemaVersion: Int = AnchorStore.anchorSchemaVersion,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.schemaVersion = schemaVersion
        self.fileManager = fileManager
    }

    /// `<Application Support>/Setmio/anchors.json`, falling back to the temporary directory when the user
    /// domain has no Application Support directory (containers, Linux CI).
    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: "Setmio", directoryHint: .isDirectory)
            .appending(path: "anchors.json", directoryHint: .notDirectory)
    }

    public static func key(for kind: HealthMetricKind, schemaVersion: Int = AnchorStore.anchorSchemaVersion) -> String {
        "\(kind.rawValue)#v\(schemaVersion)"
    }

    public func key(for kind: HealthMetricKind) -> String {
        Self.key(for: kind, schemaVersion: schemaVersion)
    }

    // MARK: Access

    public func get(_ kind: HealthMetricKind) -> Data? {
        load()[key(for: kind)]
    }

    /// Stores (or, with nil, removes) the anchor for `kind` and writes the file atomically.
    public func set(_ anchor: Data?, for kind: HealthMetricKind) throws {
        var dict = load()
        dict[key(for: kind)] = anchor
        try persist(dict)
    }

    public func reset(_ kind: HealthMetricKind) throws {
        try set(nil, for: kind)
    }

    /// Removes every anchor, including those written under older schema versions.
    public func resetAll() throws {
        try persist([:])
    }

    public func allKeys() -> [String] {
        Array(load().keys).sorted()
    }

    // MARK: Disk

    private func load() -> [String: Data] {
        if let cache { return cache }
        var loaded: [String: Data] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            loaded = decoded
        }
        cache = loaded
        return loaded
    }

    private func persist(_ dict: [String: Data]) throws {
        cache = dict
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dict)
        try data.write(to: fileURL, options: [.atomic])
    }
}
