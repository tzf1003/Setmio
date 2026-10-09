import Foundation
import Observation
import SetmioCore
import SetmioHealth

#if canImport(WatchConnectivity)
import WatchConnectivity

/// watchOS side of WatchConnectivity (方案.md §7.7): receives today's plan through the application context
/// (also cached to a file so the watch works offline across launches), and carries mirroring envelopes through
/// `transferUserInfo` when the live mirroring channel is unavailable.
@MainActor
@Observable
final class WatchConnectivityBridge: NSObject, WCSessionDelegate {
    nonisolated static let planKey = "plan"
    nonisolated static let planVersionKey = "planVersion"
    nonisolated static let envelopeKey = "envelope"
    nonisolated static let cacheFileName = "cached-plan.json"

    var onPlan: (@MainActor (PlannedSession, Int?) -> Void)?
    var onEnvelope: (@MainActor (MirroringEnvelope) async -> Void)?

    private(set) var isActivated = false
    private(set) var isReachable = false
    private(set) var lastError: String?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        // The last context the phone pushed is kept by the system across launches.
        if let plan = Self.decodePlan(from: session.receivedApplicationContext) {
            onPlan?(plan.plan, plan.version)
        }
    }

    /// Queued, guaranteed delivery of an envelope the mirroring channel could not carry.
    func transfer(_ envelope: MirroringEnvelope) {
        guard let session, session.activationState == .activated else {
            lastError = "WatchConnectivity 未激活，无法发送"
            return
        }
        do {
            session.transferUserInfo([Self.envelopeKey: try envelope.encoded()])
        } catch {
            lastError = "无法编码消息：\(error.localizedDescription)"
        }
    }

    // MARK: Plan cache

    static func cacheURL(fileManager: FileManager = .default) -> URL {
        (fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
            .appending(path: cacheFileName, directoryHint: .notDirectory)
    }

    nonisolated static func decodePlan(from context: [String: Any]) -> (plan: PlannedSession, version: Int?)? {
        guard let data = context[planKey] as? Data,
              let plan = try? MirroringEnvelope.makeDecoder().decode(PlannedSession.self, from: data) else { return nil }
        return (plan, context[planVersionKey] as? Int)
    }

    static func loadCachedPlan() -> PlannedSession? {
        guard let data = try? Data(contentsOf: cacheURL()) else { return nil }
        return try? MirroringEnvelope.makeDecoder().decode(PlannedSession.self, from: data)
    }

    static func cache(_ plan: PlannedSession) {
        guard let data = try? MirroringEnvelope.makeEncoder().encode(plan) else { return }
        try? data.write(to: cacheURL(), options: [.atomic])
    }

    // MARK: WCSessionDelegate (WatchConnectivity queue → MainActor)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let activated = activationState == .activated
        let reachable = session.isReachable
        let message = error.map { $0.localizedDescription }
        Task { @MainActor in
            self.isActivated = activated
            self.isReachable = reachable
            if let message { self.lastError = "WatchConnectivity 激活失败：\(message)" }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let decoded = Self.decodePlan(from: applicationContext) else { return }
        let plan = decoded.plan
        let version = decoded.version
        Task { @MainActor in
            Self.cache(plan)
            self.onPlan?(plan, version)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.envelopeKey] as? Data,
              let envelope = try? MirroringEnvelope.decode(data) else { return }
        Task { @MainActor in
            await self.onEnvelope?(envelope)
        }
    }
}

#else

@MainActor
@Observable
final class WatchConnectivityBridge {
    var onPlan: (@MainActor (PlannedSession, Int?) -> Void)?
    var onEnvelope: (@MainActor (MirroringEnvelope) async -> Void)?
    private(set) var isActivated = false
    private(set) var isReachable = false
    private(set) var lastError: String?
    func activate() {}
    func transfer(_ envelope: MirroringEnvelope) {}
    static func loadCachedPlan() -> PlannedSession? { nil }
    static func cache(_ plan: PlannedSession) {}
}
#endif
