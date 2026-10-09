import Foundation
import SetmioCore

// MARK: - Watch ↔ iPhone mirroring protocol (Foundation-only; see 方案.md §7.7)

/// Commands the phone's Live Activity sends back to the watch, which stays the source of truth for the timer.
public enum RestTimerCommand: String, Codable, Sendable, Hashable, CaseIterable {
    case pause, resume, skip, add30
}

/// Small JSON payloads exchanged over `HKWorkoutSession.sendToRemoteWorkoutSession(data:)` (with
/// WatchConnectivity as the fallback transport). Every message is safe to deliver more than once: the phone
/// upserts by `LoggedSet.id` / `LoggedSession.id`, and acks carry the ids they cover.
public enum MirroringMessage: Codable, Sendable, Equatable {
    /// Watch → phone, first message after mirroring starts.
    case hello(watchAppVersion: String, planVersion: Int?)
    /// Watch → phone: a set was logged; `restSeconds` drives the phone's Live Activity.
    case setLogged(LoggedSet, restSeconds: Int)
    /// Watch → phone: the user removed a set during the session.
    case setDeleted(ID<LoggedSet>)
    /// Watch → phone: the session finished (sets included for the final reconcile).
    case sessionEnded(LoggedSession)
    /// Either direction: the receiver persisted these set/session ids.
    case ack(ids: [UUID])
    /// Phone → watch: today's plan changed (readiness modulation, edits).
    case planUpdated(PlannedSession)
    /// Phone → watch: Live Activity button pressed.
    case restTimerCommand(RestTimerCommand)
    /// Watch → phone: the rest timer changed (started, paused, resumed, extended) — or ended / was skipped (`nil`).
    /// Best effort and never journaled: the watch stays the source of truth, the phone only mirrors it.
    case restTimerChanged(RestTimerState?)

    public var isAck: Bool {
        if case .ack = self { return true }
        return false
    }
}

public enum MirroringError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case malformedPayload(String)
    case noActiveSession

    public var messageZH: String {
        switch self {
        case .unsupportedVersion(let v): "不支持的镜像协议版本 v\(v)，请同时更新 iPhone 与手表 App"
        case .malformedPayload(let detail): "镜像消息无法解析：\(detail)"
        case .noActiveSession: "没有进行中的镜像会话"
        }
    }
}

/// Versioned, sequenced wrapper around one message. `seq` is per sender and monotonically increasing, so the
/// receiver can detect gaps and discard stale re-sends.
public struct MirroringEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var v: Int
    public var seq: Int
    public var message: MirroringMessage

    public init(v: Int = MirroringEnvelope.currentVersion, seq: Int, message: MirroringMessage) {
        self.v = v
        self.seq = seq
        self.message = message
    }

    // MARK: Codec (ISO 8601 with fractional seconds; sub-millisecond precision is dropped)

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle()

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalStyle.format(date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? fractionalStyle.parse(string) { return date }
            if let date = try? wholeSecondStyle.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
        }
        return decoder
    }

    public static func encode(_ envelope: MirroringEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> MirroringEnvelope {
        let envelope: MirroringEnvelope
        do {
            envelope = try makeDecoder().decode(MirroringEnvelope.self, from: data)
        } catch {
            throw MirroringError.malformedPayload(String(describing: error))
        }
        guard envelope.v <= currentVersion else { throw MirroringError.unsupportedVersion(envelope.v) }
        return envelope
    }

    public func encoded() throws -> Data {
        try Self.encode(self)
    }
}

/// Per-sender sequence counter. Value type on purpose: the owning `@MainActor` manager mutates it.
public struct MirroringSequencer: Sendable, Equatable {
    public private(set) var last: Int

    public init(last: Int = 0) { self.last = last }

    public mutating func next(_ message: MirroringMessage) -> MirroringEnvelope {
        last += 1
        return MirroringEnvelope(seq: last, message: message)
    }
}
