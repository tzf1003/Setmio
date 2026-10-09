import Foundation
import Testing
import SetmioCore
import SetmioHealth
@testable import SetmioWatch

@Suite("WatchSessionJournal 本地日志")
struct WatchSessionJournalTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleSet(sessionID: SetmioCore.ID<LoggedSession>, index: Int) -> LoggedSet {
        LoggedSet(
            sessionID: sessionID,
            exerciseID: SetmioCore.ID(),
            index: index,
            load: 60,
            reps: 10,
            rir: 2,
            completedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 120)
        )
    }

    @Test("append → replay → markAcked → purge 往返")
    func roundTrip() async throws {
        let directory = try makeDirectory()
        let journal = WatchSessionJournal(directory: directory)
        let sessionID = SetmioCore.ID<LoggedSession>()
        let first = sampleSet(sessionID: sessionID, index: 0)
        let second = sampleSet(sessionID: sessionID, index: 1)

        let entry1 = try await journal.append(MirroringEnvelope(seq: 1, message: .setLogged(first, restSeconds: 90)))
        let entry2 = try await journal.append(MirroringEnvelope(seq: 2, message: .setLogged(second, restSeconds: 180)))
        #expect(entry1.id == first.id.rawValue)
        #expect(entry2.id == second.id.rawValue)

        var pending = try await journal.replay()
        #expect(pending.map(\.id) == [first.id.rawValue, second.id.rawValue])
        #expect(pending.first?.envelope.message == .setLogged(first, restSeconds: 90))

        try await journal.markAcked(ids: [first.id.rawValue])
        pending = try await journal.replay()
        #expect(pending.map(\.id) == [second.id.rawValue])
        #expect(try await journal.entryCount() == 2)

        try await journal.purgeAcked()
        #expect(try await journal.entryCount() == 1)
        pending = try await journal.replay()
        #expect(pending.map(\.id) == [second.id.rawValue])

        // Session end + its ack empties the file; a fresh instance over the same directory agrees.
        let session = LoggedSession(id: sessionID, start: first.completedAt, end: second.completedAt, sets: [first, second], origin: .watch)
        try await journal.append(MirroringEnvelope(seq: 3, message: .sessionEnded(session)))
        try await journal.markAcked(ids: [second.id.rawValue, sessionID.rawValue])
        try await journal.purgeAcked()
        let reopened = WatchSessionJournal(directory: directory)
        #expect(try await reopened.replay().isEmpty)
        #expect(try await reopened.entryCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: reopened.fileURL.path))
    }

    @Test("损坏的行被跳过，其余条目仍可回放")
    func corruptLinesAreSkipped() async throws {
        let directory = try makeDirectory()
        let journal = WatchSessionJournal(directory: directory)
        let sessionID = SetmioCore.ID<LoggedSession>()
        let set = sampleSet(sessionID: sessionID, index: 0)
        try await journal.append(MirroringEnvelope(seq: 1, message: .setLogged(set, restSeconds: 60)))

        let handle = try FileHandle(forWritingTo: journal.fileURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()

        let pending = try await journal.replay()
        #expect(pending.map(\.id) == [set.id.rawValue])
    }
}
