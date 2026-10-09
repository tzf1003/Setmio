#if canImport(SwiftData)
import Foundation
import SwiftData

/// The only place a `ModelContainer` is built.
///
/// - Local only: `cloudKitDatabase: .none` is written explicitly so the App Store 5.1.3(ii) audit is one line.
/// - Store lives in `Application Support/Setmio/Setmio.store`.
/// - The store directory is protected with `.completeUntilFirstUserAuthentication` (not `.complete`), otherwise
///   HealthKit background delivery cannot open the database while the phone is locked.
public enum ModelContainerFactory {
    public static let directoryName = "Setmio"
    public static let storeFileName = "Setmio.store"

    /// `~/Library/Application Support/Setmio/Setmio.store` (created on demand).
    public static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// Builds the container for the current schema.
    /// - Parameters:
    ///   - inMemory: `true` for tests and previews; nothing touches disk.
    ///   - storeURL: overrides the default store file (tests, demo copies). Ignored when `inMemory` is `true`.
    public static func make(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SetmioCurrentSchema.self)
        let configuration: ModelConfiguration
        var storeDirectory: URL? = nil

        if inMemory {
            configuration = ModelConfiguration(
                "SetmioInMemory",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        } else {
            let url = try storeURL ?? defaultStoreURL()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(
                "Setmio",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none   // health-derived data never goes to iCloud (方案.md §7.9)
            )
            storeDirectory = directory
        }

        let container = try ModelContainer(
            for: schema,
            migrationPlan: SetmioMigrationPlan.self,
            configurations: [configuration]
        )

        if let storeDirectory {
            try applyFileProtection(storeDirectory: storeDirectory)
        }
        return container
    }

    // MARK: - File protection

    /// Sets `.completeUntilFirstUserAuthentication` on the store directory and on the SQLite files that already
    /// exist (`.store`, `-wal`, `-shm`). New files created in the directory inherit its class.
    static func applyFileProtection(storeDirectory: URL, fileManager: FileManager = .default) throws {
        #if os(iOS) || os(watchOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.setAttributes(attributes, ofItemAtPath: storeDirectory.path)
        for suffix in ["", "-wal", "-shm"] {
            let file = storeDirectory.appending(path: storeFileName + suffix, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.setAttributes(attributes, ofItemAtPath: file.path)
            }
        }
        #else
        _ = storeDirectory
        _ = fileManager
        #endif
    }
}
#endif
