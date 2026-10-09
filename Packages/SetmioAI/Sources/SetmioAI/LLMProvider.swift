import Foundation

/// Which model backend serves a request. Mirrors the proxy's `X-Setmio-Backend` hint.
public enum LLMProviderID: String, Sendable, Codable, CaseIterable {
    /// Claude via the Setmio proxy (deployed outside mainland China).
    case claudeProxy
    /// A domestic (PRC-registered) model via the same proxy contract. Not configured before V3.
    case domestic

    public var nameZH: String {
        switch self {
        case .claudeProxy: "Claude（代理）"
        case .domestic: "国产模型"
        }
    }
}

/// The only seam between the app and any LLM. Numbers (scores, loads, doses, TDEE) are never produced here;
/// providers only do perception (food photos / text) and language (coach replies, weekly reports).
public protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }
    func recognizeFood(_ req: FoodRecognizeRequest) async throws -> FoodRecognitionResultDTO
    func parseMealText(_ req: FoodParseTextRequest) async throws -> FoodRecognitionResultDTO
    func chat(_ req: CoachChatRequest) async throws -> CoachChatResponse
    func weeklyReport(_ req: WeeklyReportRequest) async throws -> WeeklyReportResponse
}

/// Client-side error model. Every proxy error envelope and transport failure maps onto one of these cases.
public enum LLMError: Error, Sendable, Equatable {
    /// No device token, or the proxy rejected it (re-register with an invite code).
    case unauthorized
    /// Per-device daily quota or per-IP registration quota exhausted.
    case rateLimited(retryAfter: TimeInterval?)
    /// The proxy rejected the request body (schema violation); message is the server's explanation.
    case invalidRequest(String)
    /// Request body exceeded the proxy's 2 MB limit.
    case imageTooLarge
    /// The model refused (`stop_reason == "refusal"`); never retried.
    case upstreamRefusal
    /// Model / backend failure; `retryable` comes from the envelope.
    case upstream(retryable: Bool)
    /// URLSession-level failure (offline, timeout, DNS…).
    case network(String)
    /// A 2xx body that did not decode into the expected DTO.
    case decoding(String)
    /// The selected provider is not configured (e.g. domestic backend before V3) or the proxy reports `backend_unavailable`.
    case providerUnavailable

    /// Errors `ProxyClient` retries once immediately. Rate limits are excluded on purpose: retrying would burn quota.
    public var isImmediatelyRetryable: Bool {
        switch self {
        case .upstream(let retryable): retryable
        case .network: true
        default: false
        }
    }

    public var messageZH: String {
        switch self {
        case .unauthorized: return "设备未授权，请在设置中用邀请码重新注册"
        case .rateLimited(let after):
            if let after, after > 0 {
                let minutes = Int((after / 60).rounded(.up))
                return "今日 AI 额度已用完，约 \(minutes) 分钟后再试"
            }
            return "AI 额度已用完，请稍后再试"
        case .invalidRequest(let message): return "请求无效：\(message)"
        case .imageTooLarge: return "照片过大，请重新拍摄或裁剪后再试"
        case .upstreamRefusal: return "模型拒绝了这次请求，请换一张照片或改写内容"
        case .upstream(let retryable): return retryable ? "模型暂时不可用，请稍后重试" : "模型处理失败"
        case .network(let detail): return "网络错误：\(detail)"
        case .decoding(let detail): return "响应格式错误：\(detail)"
        case .providerUnavailable: return "当前模型提供方不可用，请在设置中切换"
        }
    }
}
