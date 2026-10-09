import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Domestic model through the same proxy contract, selected with `X-Setmio-Backend: domestic`.
/// Until a mainland deployment exists (V3) the base URL is nil and every call throws `providerUnavailable`.
public struct DomesticProvider: LLMProvider {
    public static let backendHint = "domestic"

    public let id: LLMProviderID = .domestic
    public let client: ProxyClient?

    public init(client: ProxyClient?) {
        self.client = client
    }

    public init(baseURL: URL?, credentials: any DeviceCredentialStoring, session: URLSession = .shared, clientHeader: String) {
        self.init(client: baseURL.map { ProxyClient(baseURL: $0, credentials: credentials, session: session, clientHeader: clientHeader) })
    }

    public var isConfigured: Bool { client != nil }

    private func post<Req: Encodable & Sendable, Res: Decodable & Sendable>(_ path: String, _ body: Req, timeout: TimeInterval = ProxyRoute.defaultTimeout) async throws -> Res {
        guard let client else { throw LLMError.providerUnavailable }
        return try await client.post(path, body, timeout: timeout, backendHint: Self.backendHint)
    }

    public func recognizeFood(_ req: FoodRecognizeRequest) async throws -> FoodRecognitionResultDTO {
        try await post(ProxyRoute.foodRecognize, req, timeout: ProxyRoute.foodRecognizeTimeout)
    }

    public func parseMealText(_ req: FoodParseTextRequest) async throws -> FoodRecognitionResultDTO {
        try await post(ProxyRoute.foodParseText, req)
    }

    public func chat(_ req: CoachChatRequest) async throws -> CoachChatResponse {
        try await post(ProxyRoute.coachChat, req)
    }

    public func weeklyReport(_ req: WeeklyReportRequest) async throws -> WeeklyReportResponse {
        try await post(ProxyRoute.weeklyReport, req, timeout: ProxyRoute.weeklyReportTimeout)
    }
}
