import Foundation
import SetmioCore

/// Errors from writing the registry. Reads never throw.
public enum TestDataRegistryError: Error, Equatable, Sendable {
    /// The file exists but cannot be read (I/O error, or a directory sits at its path). Writing would replace
    /// tags that cannot be inspected, so writes are refused instead.
    case unreadable
    /// A corrupt file could not be copied aside before it was replaced.
    case couldNotPreserveCorruptFile
}

/// Which training sessions are test data, and whether new sessions should be tagged automatically.
///
/// The tags live in a small local JSON file next to the SwiftData store, not in SwiftData itself: adding an attribute
/// to a `@Model` would need a versioned migration on the user's existing store. Deletion of test data only ever
/// touches sessions listed here, so an untagged (real) session cannot be removed by it.
///
/// Reads never throw: a missing or corrupt file reads as "no tags" and "test mode off". Writes are atomic, and a
/// corrupt file is copied to `test-data.corrupt.json` before it is replaced, so no tag is silently lost.
public actor TestDataRegistry {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    // MARK: Reads

    public func isTest(_ sessionID: ID<LoggedSession>) -> Bool {
        current().testSessionIDs.contains(sessionID.rawValue)
    }

    public func testSessionIDs() -> Set<ID<LoggedSession>> {
        Set(current().testSessionIDs.map { ID<LoggedSession>($0) })
    }

    public func testMode() -> Bool {
        current().testMode
    }

    // MARK: Writes

    public func mark(_ sessionID: ID<LoggedSession>) throws {
        try markMany([sessionID])
    }

    public func markMany(_ sessionIDs: [ID<LoggedSession>]) throws {
        try update { file in
            for id in sessionIDs { file.testSessionIDs.insert(id.rawValue) }
        }
    }

    public func unmark(_ sessionID: ID<LoggedSession>) throws {
        try update { file in
            file.testSessionIDs.remove(sessionID.rawValue)
        }
    }

    /// Drops tags for sessions that no longer exist (after a deletion).
    public func forget(_ sessionIDs: [ID<LoggedSession>]) throws {
        try update { file in
            for id in sessionIDs { file.testSessionIDs.remove(id.rawValue) }
        }
    }

    public func setTestMode(_ enabled: Bool) throws {
        try update { file in
            file.testMode = enabled
        }
    }

    /// Tags `sessionID` only while test mode is on. Returns whether it was tagged. Does not write when test mode is off.
    @discardableResult
    public func markIfTestMode(_ sessionID: ID<LoggedSession>) throws -> Bool {
        guard current().testMode else { return false }
        try mark(sessionID)
        return true
    }

    // MARK: Disk

    /// In-memory state.
    private struct File: Equatable {
        var testMode: Bool
        var testSessionIDs: Set<UUID>

        static let empty = File(testMode: false, testSessionIDs: [])
    }

    /// On-disk form. Tags are written sorted so the file is stable and diff-able.
    private struct OnDisk: Codable {
        var schemaVersion: Int
        var testMode: Bool
        var testSessionIDs: [UUID]
    }

    static let schemaVersion = 1

    private enum Loaded {
        case missing
        case valid(File)
        case corrupt(Data)
        case unreadable
    }

    private var corruptFileURL: URL {
        fileURL.deletingLastPathComponent().appending(path: "test-data.corrupt.json", directoryHint: .notDirectory)
    }

    private func load() -> Loaded {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unreadable }
        guard let onDisk = try? JSONDecoder().decode(OnDisk.self, from: data),
              onDisk.schemaVersion == Self.schemaVersion else { return .corrupt(data) }
        return .valid(File(testMode: onDisk.testMode, testSessionIDs: Set(onDisk.testSessionIDs)))
    }

    /// The file's contents for reads: anything other than a valid file reads as empty.
    private func current() -> File {
        if case .valid(let file) = load() { return file }
        return .empty
    }

    /// Read-modify-write. Refuses to replace a file it cannot read.
    private func update(_ change: (inout File) -> Void) throws {
        var file: File
        switch load() {
        case .missing:
            file = .empty
        case .valid(let existing):
            file = existing
        case .corrupt(let data):
            do {
                try data.write(to: corruptFileURL, options: .atomic)
            } catch {
                throw TestDataRegistryError.couldNotPreserveCorruptFile
            }
            file = .empty
        case .unreadable:
            throw TestDataRegistryError.unreadable
        }
        change(&file)
        try persist(file)
    }

    private func persist(_ file: File) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let onDisk = OnDisk(
            schemaVersion: Self.schemaVersion,
            testMode: file.testMode,
            testSessionIDs: file.testSessionIDs.sorted { $0.uuidString < $1.uuidString }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // `.atomic` writes a temporary file in the same directory and renames it over the old one.
        try encoder.encode(onDisk).write(to: fileURL, options: .atomic)
    }
}
