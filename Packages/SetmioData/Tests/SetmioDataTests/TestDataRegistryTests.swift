import Foundation
import Testing
import SetmioCore
@testable import SetmioData

/// Foundation-only: runs on Linux as well as macOS.
@Suite("TestDataRegistry · 测试数据标记文件", .serialized)
struct TestDataRegistryTests {
    /// A fresh file path in its own directory (the directory is created on first write).
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "setmio-test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "test-data.json", directoryHint: .notDirectory)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("文件不存在时全部读作空，读取不会创建文件")
    func missingFileReadsEmpty() async throws {
        let url = makeURL()
        let registry = TestDataRegistry(fileURL: url)
        #expect(await registry.testSessionIDs().isEmpty)
        #expect(await registry.testMode() == false)
        #expect(await registry.isTest(ID()) == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("标记、取消标记与测试模式跨实例保留")
    func persistsAcrossInstances() async throws {
        let url = makeURL()
        let kept = ID<LoggedSession>()
        let removed = ID<LoggedSession>()

        let first = TestDataRegistry(fileURL: url)
        try await first.mark(kept)
        try await first.mark(removed)
        try await first.unmark(removed)
        try await first.setTestMode(true)

        let second = TestDataRegistry(fileURL: url)
        #expect(await second.testSessionIDs() == [kept])
        #expect(await second.isTest(kept))
        #expect(await second.isTest(removed) == false)
        #expect(await second.testMode())
    }

    @Test("markMany 与 forget 按集合生效")
    func markManyAndForget() async throws {
        let registry = TestDataRegistry(fileURL: makeURL())
        let ids = (0..<4).map { _ in ID<LoggedSession>() }
        try await registry.markMany(ids)
        #expect(await registry.testSessionIDs() == Set(ids))

        try await registry.forget([ids[0], ids[2]])
        #expect(await registry.testSessionIDs() == [ids[1], ids[3]])
    }

    @Test("写入是原子的：目录里只剩标记文件，且每次写入后都是完整 JSON")
    func atomicWrite() async throws {
        let url = makeURL()
        let registry = TestDataRegistry(fileURL: url)
        for _ in 0..<5 {
            try await registry.mark(ID())
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(entries == ["test-data.json"])
        let object = try jsonObject(at: url)
        #expect((object["testSessionIDs"] as? [String])?.count == 5)
    }

    @Test("损坏的文件读作空；下一次写入前把原内容另存，不静默覆盖")
    func corruptFileIsKeptAside() async throws {
        let url = makeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: url)

        let registry = TestDataRegistry(fileURL: url)
        #expect(await registry.testSessionIDs().isEmpty)
        #expect(await registry.testMode() == false)

        let session = ID<LoggedSession>()
        try await registry.mark(session)
        #expect(await registry.testSessionIDs() == [session])

        let sidecar = url.deletingLastPathComponent().appending(path: "test-data.corrupt.json", directoryHint: .notDirectory)
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "not json {")
    }

    @Test("文件无法读取（路径是目录）时读作空，写入失败而不是覆盖")
    func unreadableFileRefusesWrites() async throws {
        let url = makeURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let registry = TestDataRegistry(fileURL: url)
        #expect(await registry.testSessionIDs().isEmpty)
        await #expect(throws: TestDataRegistryError.self) {
            try await registry.mark(ID())
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test("markIfTestMode 只在测试模式开启时标记，关闭时既不标记也不写文件")
    func markIfTestModeOnlyWhenOn() async throws {
        let url = makeURL()
        let registry = TestDataRegistry(fileURL: url)
        let session = ID<LoggedSession>()

        #expect(try await registry.markIfTestMode(session) == false)
        #expect(await registry.isTest(session) == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        try await registry.setTestMode(true)
        #expect(try await registry.markIfTestMode(session) == true)
        #expect(await registry.isTest(session))

        try await registry.setTestMode(false)
        let later = ID<LoggedSession>()
        #expect(try await registry.markIfTestMode(later) == false)
        #expect(await registry.isTest(later) == false)
    }
}

#if canImport(SwiftData)
@Suite("TestDataRegistry · 默认位置")
struct TestDataRegistryDefaultLocationTests {
    @Test("默认标记文件与数据库在同一目录")
    func sitsBesideStore() throws {
        let store = try ModelContainerFactory.defaultStoreURL()
        let tags = TestDataRegistry.defaultFileURL()
        #expect(tags.deletingLastPathComponent() == store.deletingLastPathComponent())
        #expect(tags.lastPathComponent == "test-data.json")
    }
}
#endif
