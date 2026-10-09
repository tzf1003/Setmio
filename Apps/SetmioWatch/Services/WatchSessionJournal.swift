import Foundation
import SetmioCore
import SetmioHealth

/// Append-only JSON Lines journal of outbound mirroring envelopes, written *before* each send so a crash,
/// a dropped mirroring channel or an unreachable iPhone never loses a logged set (方案.md §7.7).
///
/// File format (one JSON object per line, UTF-8, `\n`-terminated):
/// - `{"entry": {"id": …, "envelope": …, "acked": false, "recordedAt": …}}` appended by `append`;
/// - `{"ack": ["<uuid>", …]}` appended by `markAcked` (so a workout never rewrites the file);
/// - `purgeAcked` rewrites the file with only the entries that are still unacked.
/// Every append is followed by `fsync`. Corrupt lines are skipped on read.
///
/// Foundation-only, so it builds and tests on Linux.
public actor WatchSessionJournal {
    public struct Entry: Codable, Sendable, Equatable {
        /// The id the phone acks: `LoggedSet.id` / `LoggedSession.id` (or a fresh UUID for other messages).
        public var id: UUID
        public var envelope: MirroringEnvelope
        public var acked: Bool
        public var recordedAt: Date

        public init(id: UUID, envelope: MirroringEnvelope, acked: Bool = false, recordedAt: Date) {
            self.id = id
            self.envelope = envelope
            self.acked = acked
            self.recordedAt = recordedAt
        }
    }

    /// One line of the file.
    private struct Line: Codable {
        var entry: Entry?
        var ack: [UUID]?
    }

    public static let defaultFileName = "session-journal.jsonl"

    public let fileURL: URL
    private let fileManager: FileManager

    /// `directory` defaults to the app's Documents directory.
    public init(directory: URL? = nil, fileName: String = WatchSessionJournal.defaultFileName, fileManager: FileManager = .default) {
        let base = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.fileURL = base.appending(path: fileName, directoryHint: .notDirectory)
        self.fileManager = fileManager
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    }

    /// The id the phone will ack for a message, if it carries one.
    public static func journalID(for message: MirroringMessage) -> UUID? {
        switch message {
        case .setLogged(let set, _): set.id.rawValue
        case .setDeleted(let id): id.rawValue
        case .sessionEnded(let session): session.id.rawValue
        case .hello, .ack, .planUpdated, .restTimerCommand: nil
        }
    }

    // MARK: Writes

    /// Appends the envelope and fsyncs. Returns the stored entry (its `id` is what the phone acks).
    @discardableResult
    public func append(_ envelope: MirroringEnvelope, now: Date = Date()) throws -> Entry {
        let entry = Entry(id: Self.journalID(for: envelope.message) ?? UUID(), envelope: envelope, recordedAt: now)
        try appendLine(Line(entry: entry, ack: nil))
        return entry
    }

    /// Records an ack from the phone. Unknown ids are harmless (the phone acks session *and* set ids).
    public func markAcked(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try appendLine(Line(entry: nil, ack: ids))
    }

    /// Rewrites the file keeping only unacked entries (call after the session's final ack).
    public func purgeAcked() throws {
        let remaining = try replay()
        if remaining.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        var data = Data()
        for entry in remaining {
            data.append(try Self.encodeLine(Line(entry: entry, ack: nil)))
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: Reads

    /// Entries not yet acked, in append order. Call at launch to re-send after a crash.
    public func replay() throws -> [Entry] {
        var order: [UUID] = []
        var entries: [UUID: Entry] = [:]
        for line in try readLines() {
            if let entry = line.entry {
                if entries[entry.id] == nil { order.append(entry.id) }
                entries[entry.id] = entry
            }
            if let acked = line.ack {
                for id in acked { entries[id]?.acked = true }
            }
        }
        return order.compactMap { entries[$0] }.filter { !$0.acked }
    }

    /// Total entries recorded in the file (acked or not).
    public func entryCount() throws -> Int {
        try readLines().filter { $0.entry != nil }.count
    }

    /// Unacked entries older than `days` (the Settings screen warns the user to handle them by hand).
    public func staleEntries(olderThan days: Int, now: Date = Date()) throws -> [Entry] {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return try replay().filter { $0.recordedAt < cutoff }
    }

    // MARK: Disk

    private func appendLine(_ line: Line) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: [.atomic])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Self.encodeLine(line))
        try handle.synchronize()   // fsync: the entry must survive a crash before the send is attempted
    }

    private func readLines() throws -> [Line] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = MirroringEnvelope.makeDecoder()
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).compactMap { slice in
            try? decoder.decode(Line.self, from: Data(slice))
        }
    }

    private static func encodeLine(_ line: Line) throws -> Data {
        // The mirroring encoder has no `.prettyPrinted`, so a line never contains a newline.
        var data = try MirroringEnvelope.makeEncoder().encode(line)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
