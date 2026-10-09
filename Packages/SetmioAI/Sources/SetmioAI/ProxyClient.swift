import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin HTTP client for `proxy/`: bearer device token, client / backend headers, error-envelope decoding,
/// one immediate retry on retryable failures. Both providers are built on it.
public struct ProxyClient: Sendable {
    public let baseURL: URL
    public let credentials: any DeviceCredentialStoring
    public let clientHeader: String
    /// Milliseconds to wait before the single retry (0 in tests).
    public let retryDelay: Duration
    private let transport: Transport

    /// Abstracts `URLSession` so Linux tests can stub the network without `URLProtocol` subclassing on every platform.
    public struct Transport: Sendable {
        public let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

        public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
            self.send = send
        }

        public static func urlSession(_ session: URLSession) -> Transport {
            Transport { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.network("非 HTTP 响应")
                }
                return (data, http)
            }
        }
    }

    public init(baseURL: URL, credentials: any DeviceCredentialStoring, session: URLSession = .shared, clientHeader: String, retryDelay: Duration = .milliseconds(300)) {
        self.init(baseURL: baseURL, credentials: credentials, transport: .urlSession(session), clientHeader: clientHeader, retryDelay: retryDelay)
    }

    public init(baseURL: URL, credentials: any DeviceCredentialStoring, transport: Transport, clientHeader: String, retryDelay: Duration = .milliseconds(300)) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.clientHeader = clientHeader
        self.retryDelay = retryDelay
    }

    // MARK: Requests

    /// POSTs `body` as JSON and decodes `Res`. Non-2xx responses are decoded as `ErrorEnvelope` → `LLMError`.
    public func post<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        _ path: String,
        _ body: Req,
        timeout: TimeInterval = ProxyRoute.defaultTimeout,
        backendHint: String? = nil
    ) async throws -> Res {
        let request = try makeRequest(path: path, body: body, timeout: timeout, backendHint: backendHint)
        do {
            return try await perform(request, as: Res.self)
        } catch let error as LLMError where error.isImmediatelyRetryable {
            if retryDelay > .zero { try? await Task.sleep(for: retryDelay) }
            return try await perform(request, as: Res.self)
        }
    }

    /// Exchanges an invite code for a device token and stores it in `credentials`.
    @discardableResult
    public func register(inviteCode: String, deviceName: String, platform: String = "ios") async throws -> DeviceRegisterResponse {
        let response: DeviceRegisterResponse = try await post(
            ProxyRoute.register,
            DeviceRegisterRequest(inviteCode: inviteCode, deviceName: deviceName, platform: platform)
        )
        try credentials.store(response.deviceToken)
        return response
    }

    public var isRegistered: Bool {
        (try? credentials.token()) != nil
    }

    // MARK: Internals

    func makeRequest<Req: Encodable>(path: String, body: Req, timeout: TimeInterval, backendHint: String?) throws -> URLRequest {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(trimmed))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientHeader, forHTTPHeaderField: "X-Setmio-Client")
        if let backendHint {
            request.setValue(backendHint, forHTTPHeaderField: "X-Setmio-Backend")
        }
        if let token = try credentials.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try AIJSON.encoder().encode(body)
        } catch {
            throw LLMError.invalidRequest("请求编码失败：\(error)")
        }
        return request
    }

    private func perform<Res: Decodable>(_ request: URLRequest, as _: Res.Type) async throws -> Res {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.network(Self.describe(error))
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapFailure(status: response.statusCode, data: data, headers: response.allHeaderFields)
        }
        do {
            return try AIJSON.decoder().decode(Res.self, from: data)
        } catch {
            throw LLMError.decoding(String(describing: error))
        }
    }

    static func mapFailure(status: Int, data: Data, headers: [AnyHashable: Any]) -> LLMError {
        if let envelope = try? AIJSON.decoder().decode(ErrorEnvelope.self, from: data) {
            return envelope.llmError
        }
        switch status {
        case 401, 403: return .unauthorized
        case 413: return .imageTooLarge
        case 429:
            let header = headers["Retry-After"] as? String ?? headers["retry-after"] as? String
            return .rateLimited(retryAfter: header.flatMap(Double.init))
        case 400, 422: return .invalidRequest("HTTP \(status)")
        case 503: return .providerUnavailable
        case 500...599: return .upstream(retryable: true)
        default: return .upstream(retryable: false)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet: return "未连接网络"
            case NSURLErrorTimedOut: return "请求超时"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "无法连接代理服务器"
            default: break
            }
        }
        return nsError.localizedDescription
    }
}
