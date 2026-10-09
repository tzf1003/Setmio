import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude via the Setmio proxy (default provider). The proxy picks its default backend; no hint is sent.
public struct ClaudeProxyProvider: LLMProvider {
    public let id: LLMProviderID = .claudeProxy
    public let client: ProxyClient

    public init(client: ProxyClient) {
        self.client = client
    }

    public init(baseURL: URL, credentials: any DeviceCredentialStoring, session: URLSession = .shared, clientHeader: String) {
        self.init(client: ProxyClient(baseURL: baseURL, credentials: credentials, session: session, clientHeader: clientHeader))
    }

    public func recognizeFood(_ req: FoodRecognizeRequest) async throws -> FoodRecognitionResultDTO {
        try await client.post(ProxyRoute.foodRecognize, req, timeout: ProxyRoute.foodRecognizeTimeout)
    }

    public func parseMealText(_ req: FoodParseTextRequest) async throws -> FoodRecognitionResultDTO {
        try await client.post(ProxyRoute.foodParseText, req)
    }

    public func chat(_ req: CoachChatRequest) async throws -> CoachChatResponse {
        try await client.post(ProxyRoute.coachChat, req)
    }

    public func weeklyReport(_ req: WeeklyReportRequest) async throws -> WeeklyReportResponse {
        try await client.post(ProxyRoute.weeklyReport, req, timeout: ProxyRoute.weeklyReportTimeout)
    }
}
