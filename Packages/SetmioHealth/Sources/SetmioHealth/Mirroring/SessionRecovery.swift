import Foundation
import SetmioCore

/// The sets of a watch session that was still running when the app died.
public struct RecoveredSession: Sendable, Equatable {
    public var sessionID: ID<LoggedSession>
    /// Surviving sets (deleted ones removed), oldest first.
    public var sets: [LoggedSet]

    public init(sessionID: ID<LoggedSession>, sets: [LoggedSet]) {
        self.sessionID = sessionID
        self.sets = sets
    }
}

/// Rebuilds the in-progress session from the watch journal after `recoverActiveWorkoutSession()` (方案.md §7.7:
/// 「训练中强杀手表 App 可恢复」). Pure and Foundation-only so it is tested on Linux.
public enum SessionRecovery {
    /// - Parameter messages: every journaled outbound message in append order, acked or not.
    /// - Returns: the most recently active session that has no `.sessionEnded`, or nil when none is open.
    public static func unfinishedSession(from messages: [MirroringMessage]) -> RecoveredSession? {
        var ended: Set<ID<LoggedSession>> = []
        var deleted: Set<ID<LoggedSet>> = []
        var order: [ID<LoggedSession>] = []
        var setsBySession: [ID<LoggedSession>: [ID<LoggedSet>: LoggedSet]] = [:]

        for message in messages {
            switch message {
            case .setLogged(let set, _):
                if setsBySession[set.sessionID] == nil { order.append(set.sessionID) }
                setsBySession[set.sessionID, default: [:]][set.id] = set   // re-sends and edits collapse by id
            case .setDeleted(let id):
                deleted.insert(id)
            case .sessionEnded(let session):
                ended.insert(session.id)
            case .hello, .ack, .planUpdated, .restTimerCommand, .restTimerChanged:
                break
            }
        }

        let candidates: [RecoveredSession] = order.compactMap { id in
            guard !ended.contains(id), let sets = setsBySession[id] else { return nil }
            let surviving = sets.values.filter { !deleted.contains($0.id) }.sorted { ($0.completedAt, $0.index) < ($1.completedAt, $1.index) }
            return surviving.isEmpty ? nil : RecoveredSession(sessionID: id, sets: surviving)
        }
        return candidates.max { ($0.sets.last?.completedAt ?? .distantPast) < ($1.sets.last?.completedAt ?? .distantPast) }
    }
}
