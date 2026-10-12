#if canImport(SwiftData)
import Foundation

public extension TestDataRegistry {
    /// `test-data.json` in the same directory as the store (`Application Support/Setmio/`), so it is protected the
    /// same way. Falls back to the temporary directory only when the store location cannot be resolved.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let directory = (try? ModelContainerFactory.defaultStoreURL(fileManager: fileManager).deletingLastPathComponent())
            ?? fileManager.temporaryDirectory
        return directory.appending(path: "test-data.json", directoryHint: .notDirectory)
    }
}
#endif
