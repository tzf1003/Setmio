import Foundation
import Observation
import SetmioCore
import SetmioHealth

#if canImport(WatchConnectivity)
import WatchConnectivity

/// iPhone side of WatchConnectivity (方案.md §7.7):
/// - today's `PlannedSession` goes out through `updateApplicationContext(["plan": json, "planVersion": n])`
///   (the system keeps only the latest, which is exactly the semantics we want);
/// - watch envelopes that could not be mirrored arrive through `transferUserInfo` and are forwarded to the host;
/// - acks for those go back the same way.
///
/// Delegate callbacks come in on a WatchConnectivity queue; they are `nonisolated` and hop to the main actor
/// after extracting the Sendable bits (`Data`, `Int`, `Bool`).
@MainActor
@Observable
final class PhoneConnectivityBridge: NSObject, WCSessionDelegate {
    nonisolated static let planKey = "plan"
    nonisolated static let planVersionKey = "planVersion"
    nonisolated static let envelopeKey = "envelope"

    var onEnvelope: (@MainActor (MirroringEnvelope) async -> Void)?

    private(set) var isActivated = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var lastPushedPlanVersion: Int?
    private(set) var lastError: String?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Replaces the watch's cached plan. Throws when WatchConnectivity rejects the context (not activated,
    /// payload too large…).
    func pushPlan(_ plan: PlannedSession, version: Int) throws {
        guard let session, session.activationState == .activated else { return }
        let data = try MirroringEnvelope.makeEncoder().encode(plan)
        try session.updateApplicationContext([Self.planKey: data, Self.planVersionKey: version])
        lastPushedPlanVersion = version
    }

    /// Queued, guaranteed delivery (survives app termination) — used for acks when mirroring is unavailable.
    func transfer(_ envelope: MirroringEnvelope) {
        guard let session, session.activationState == .activated else { return }
        do {
            let data = try envelope.encoded()
            session.transferUserInfo([Self.envelopeKey: data])
        } catch {
            lastError = "无法发送到手表：\(error.localizedDescription)"
        }
    }

    // MARK: WCSessionDelegate (WatchConnectivity queue → MainActor)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let activated = activationState == .activated
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        let message = error.map { $0.localizedDescription }
        Task { @MainActor in
            self.isActivated = activated
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
            if let message { self.lastError = "WatchConnectivity 激活失败：\(message)" }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required after the user switches watches.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
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

/// Stub for platforms without WatchConnectivity (keeps `AppEnvironment` compiling everywhere).
@MainActor
@Observable
final class PhoneConnectivityBridge {
    var onEnvelope: (@MainActor (MirroringEnvelope) async -> Void)?
    private(set) var isActivated = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var lastPushedPlanVersion: Int?
    private(set) var lastError: String?

    func activate() {}
    func pushPlan(_ plan: PlannedSession, version: Int) throws { lastPushedPlanVersion = version }
    func transfer(_ envelope: MirroringEnvelope) {}
}
#endif
