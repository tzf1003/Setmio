import Foundation
import Testing
import SetmioCore
@testable import SetmioAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Fixtures

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - URLProtocol stub

/// Queued canned responses, served in order. Records every request so headers and bodies can be asserted.
final class StubURLProtocol: URLProtocol {
    struct Canned: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Canned] = []
        private(set) var requests: [(request: URLRequest, body: Data?)] = []

        func enqueue(_ canned: Canned) {
            lock.lock(); defer { lock.unlock() }
            queue.append(canned)
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            queue.removeAll()
            requests.removeAll()
        }

        func next(for request: URLRequest, body: Data?) -> Canned? {
            lock.lock(); defer { lock.unlock() }
            requests.append((request, body))
            return queue.isEmpty ? nil : queue.removeFirst()
        }

        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return requests.count
        }

        func request(at index: Int) -> (request: URLRequest, body: Data?)? {
            lock.lock(); defer { lock.unlock() }
            return requests.indices.contains(index) ? requests[index] : nil
        }
    }

    static let state = State()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        guard let canned = Self.state.next(for: request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// On Apple platforms URLSession hands the body to a custom protocol as a stream, not `httpBody`.
    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func makeClient(store: InMemoryCredentialStore = InMemoryCredentialStore(token: "tok_test"), clientHeader: String = "ios/0.1 test") -> ProxyClient {
    ProxyClient(
        baseURL: URL(string: "https://proxy.example.test")!,
        credentials: store,
        session: StubURLProtocol.session(),
        clientHeader: clientHeader,
        retryDelay: .zero
    )
}

func envelope(_ code: String, message: String = "m", retryable: Bool = false, retryAfterSeconds: Double? = nil) -> Data {
    try! AIJSON.encoder().encode(ErrorEnvelope(error: .init(code: code, message: message, retryable: retryable, retryAfterSeconds: retryAfterSeconds)))
}

func llmError(_ body: () async throws -> Void) async -> LLMError? {
    do {
        try await body()
        return nil
    } catch let error as LLMError {
        return error
    } catch {
        return nil
    }
}

// MARK: - DTO contract

@Suite("AI contract: DTOs")
struct ContractDecodingTests {
    @Test("food_recognize_response.json decodes and maps to Core FoodItems")
    func decodeFoodFixture() throws {
        let data = try Fixture.data("food_recognize_response")
        let dto = try AIJSON.decoder().decode(FoodRecognitionResultDTO.self, from: data)

        #expect(dto.items.count == 3)
        #expect(dto.overallConfidence == 0.74)
        #expect(dto.model == ModelInfo(provider: "claude", id: "claude-opus-5-5"))
        #expect(dto.items[0].nameZH == "番茄炒蛋")
        #expect(dto.items[0].portion.unit == "份")
        #expect(dto.items[0].kcal == .init(low: 200, best: 260, high: 340))
        #expect(dto.items[0].needsConfirmation)
        #expect(dto.items[1].needsConfirmation == false)
        #expect(dto.itemsNeedingConfirmation.count == 2)

        let items = dto.toFoodItems()
        #expect(items.count == 3)
        let eggs = items[0]
        #expect(eggs.nameZH == "番茄炒蛋")
        #expect(eggs.nameEN == "Scrambled eggs with tomato")
        #expect(eggs.portionGrams == 220)
        #expect(eggs.portionLabel == "1份")
        #expect(eggs.facts.kcal == 260)
        #expect(eggs.facts.protein == 13)
        #expect(eggs.facts.carbs == 9)
        #expect(eggs.facts.fat == 19)
        #expect(eggs.kcalLow == 200)
        #expect(eggs.kcalHigh == 340)
        #expect(eggs.confidence == 0.72)
        #expect(eggs.source == .photoLLM)
        #expect(eggs.originalKcalEstimate == 260)
        #expect(items[1].portionLabel == "1碗")

        let textItems = dto.toFoodItems(source: .textLLM)
        #expect(textItems.allSatisfy { $0.source == .textLLM })

        let entry = FoodEntry(day: DayKey(year: 2026, month: 10, day: 9), time: Date(timeIntervalSince1970: 1_790_000_000), meal: .lunch, items: items, confirmed: false)
        #expect(entry.totals.kcal == 260 + 232 + 45)
    }

    @Test("fixture round-trips through the DTO without losing fields")
    func roundTrip() throws {
        let data = try Fixture.data("food_recognize_response")
        let dto = try AIJSON.decoder().decode(FoodRecognitionResultDTO.self, from: data)
        let encoded = try AIJSON.encoder().encode(dto)
        let again = try AIJSON.decoder().decode(FoodRecognitionResultDTO.self, from: encoded)
        #expect(again == dto)

        // Key set must match the wire contract exactly (no renamed / dropped keys).
        let original = try Fixture.json(data)
        let mine = try Fixture.json(encoded)
        #expect(Set(original.keys) == Set(mine.keys))
        let item0 = try #require((original["items"] as? [[String: Any]])?.first)
        let mine0 = try #require((mine["items"] as? [[String: Any]])?.first)
        #expect(Set(item0.keys) == Set(mine0.keys))
        #expect(Set((item0["portion"] as! [String: Any]).keys) == ["amount", "unit", "gramsEstimate"])
        #expect(Set((mine0["kcal"] as! [String: Any]).keys) == ["low", "best", "high"])
        #expect(Set((mine0["macrosBest"] as! [String: Any]).keys) == ["proteinG", "carbsG", "fatG"])
    }

    @Test("FoodRecognizeRequest encodes the §7.8 keys")
    func encodeRecognizeRequest() throws {
        let req = FoodRecognizeRequest(
            imageJpegBase64: "/9j/4AAQ",
            imageWidth: 1536,
            imageHeight: 1152,
            hints: FoodHints(mealType: .lunch, locale: "zh-CN", userNote: "外卖", recentFoods: ["米饭", "鸡胸肉"])
        )
        let json = try Fixture.json(AIJSON.encoder().encode(req))
        #expect(Set(json.keys) == ["imageJpegBase64", "imageWidth", "imageHeight", "hints"])
        let hints = try #require(json["hints"] as? [String: Any])
        #expect(Set(hints.keys) == ["mealType", "locale", "userNote", "recentFoods"])
        #expect(hints["mealType"] as? String == "lunch")
        #expect(json["imageWidth"] as? Int == 1536)

        // Optional hints are omitted, not null.
        let minimal = try Fixture.json(AIJSON.encoder().encode(FoodRecognizeRequest(imageJpegBase64: "x", imageWidth: 1, imageHeight: 1)))
        let minimalHints = try #require(minimal["hints"] as? [String: Any])
        #expect(Set(minimalHints.keys) == ["locale"])
    }

    @Test("other requests encode their contract keys")
    func encodeOtherRequests() throws {
        let parse = try Fixture.json(AIJSON.encoder().encode(FoodParseTextRequest(text: "一碗米饭和番茄炒蛋")))
        #expect(Set(parse.keys) == ["text", "locale"])

        let chat = CoachChatRequest(
            messages: [ChatMessage(role: .user, content: "今天练腿吗？")],
            context: CoachContext(readinessScore: 72, weightTrendKgPerWeek: -0.4, tdee: 2350, proteinTargetG: 130, last7DaysSessions: 3, glp1Summary: "替尔泊肽 5 mg")
        )
        let chatJSON = try Fixture.json(AIJSON.encoder().encode(chat))
        #expect(Set(chatJSON.keys) == ["messages", "context", "locale"])
        let context = try #require(chatJSON["context"] as? [String: Any])
        #expect(Set(context.keys) == ["readinessScore", "weightTrendKgPerWeek", "tdee", "proteinTargetG", "last7DaysSessions", "glp1Summary"])
        let message = try #require((chatJSON["messages"] as? [[String: Any]])?.first)
        #expect(message["role"] as? String == "user")

        let report = WeeklyReportRequest(
            weekStart: DayKey(year: 2026, month: 10, day: 5),
            metrics: ["avgReadiness": 68],
            training: ["sessions": 3],
            nutrition: ["avgKcal": 1850],
            medication: MedicationSummaryDTO(adherencePct: 100, sideEffectSummary: "轻度恶心 2 天")
        )
        let reportJSON = try Fixture.json(AIJSON.encoder().encode(report))
        #expect(Set(reportJSON.keys) == ["weekStart", "metrics", "training", "nutrition", "medication"])
        #expect(reportJSON["weekStart"] as? String == "2026-10-05")
        #expect(Set((reportJSON["medication"] as! [String: Any]).keys) == ["adherencePct", "sideEffectSummary"])

        let register = try Fixture.json(AIJSON.encoder().encode(DeviceRegisterRequest(inviteCode: "abc", deviceName: "iPhone")))
        #expect(Set(register.keys) == ["inviteCode", "deviceName", "platform"])
    }

    @Test("responses decode")
    func decodeResponses() throws {
        let chat = try AIJSON.decoder().decode(CoachChatResponse.self, from: Data(#"{"replyZH":"可以练","suggestions":["深蹲 3 组"],"safetyFlags":[]}"#.utf8))
        #expect(chat.replyZH == "可以练")
        #expect(chat.suggestions == ["深蹲 3 组"])

        let report = try AIJSON.decoder().decode(WeeklyReportResponse.self, from: Data(#"{"titleZH":"本周","summaryZH":"好","highlights":["a"],"concerns":[],"nextWeekFocus":["b"]}"#.utf8))
        #expect(report.nextWeekFocus == ["b"])

        let registered = try AIJSON.decoder().decode(DeviceRegisterResponse.self, from: Data(#"{"deviceToken":"t","deviceId":"d"}"#.utf8))
        #expect(registered.deviceId == "d")
    }

    @Test("error envelope fixture maps to LLMError")
    func errorEnvelope() throws {
        let data = try Fixture.data("error_envelope_rate_limited")
        let envelope = try AIJSON.decoder().decode(ErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "rate_limited")
        #expect(envelope.error.retryable)
        #expect(envelope.llmError == .rateLimited(retryAfter: 3600))

        #expect(ErrorEnvelope(error: .init(code: "unauthorized", message: "", retryable: false)).llmError == .unauthorized)
        #expect(ErrorEnvelope(error: .init(code: "upstream_refusal", message: "", retryable: false)).llmError == .upstreamRefusal)
        #expect(ErrorEnvelope(error: .init(code: "upstream_error", message: "", retryable: true)).llmError == .upstream(retryable: true))
        #expect(ErrorEnvelope(error: .init(code: "backend_unavailable", message: "", retryable: false)).llmError == .providerUnavailable)
        #expect(ErrorEnvelope(error: .init(code: "image_too_large", message: "", retryable: false)).llmError == .imageTooLarge)
        #expect(ErrorEnvelope(error: .init(code: "invalid_request", message: "bad", retryable: false)).llmError == .invalidRequest("bad"))
        #expect(ErrorEnvelope(error: .init(code: "something_new", message: "", retryable: false)).llmError == .upstream(retryable: false))
        #expect(LLMError.rateLimited(retryAfter: 90).messageZH.contains("2 分钟"))
    }
}

// MARK: - ProxyClient over the stub

@Suite("AI contract: ProxyClient", .serialized)
struct ProxyClientTests {
    init() {
        StubURLProtocol.state.reset()
    }

    @Test("200 returns the decoded DTO and sends the contract headers")
    func success() async throws {
        let fixture = try Fixture.data("food_recognize_response")
        StubURLProtocol.state.enqueue(.init(status: 200, body: fixture))

        let provider = ClaudeProxyProvider(client: makeClient())
        let result = try await provider.recognizeFood(FoodRecognizeRequest(imageJpegBase64: "AAAA", imageWidth: 10, imageHeight: 10))
        #expect(result.items.count == 3)
        #expect(result.toFoodItems().first?.nameZH == "番茄炒蛋")

        let sent = try #require(StubURLProtocol.state.request(at: 0))
        #expect(sent.request.url?.path == "/v1/food/recognize")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_test")
        #expect(sent.request.value(forHTTPHeaderField: "X-Setmio-Client") == "ios/0.1 test")
        #expect(sent.request.value(forHTTPHeaderField: "X-Setmio-Backend") == nil)
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try Fixture.json(try #require(sent.body))
        #expect(body["imageJpegBase64"] as? String == "AAAA")
        #expect(StubURLProtocol.state.requestCount == 1)
    }

    @Test("429 with retryAfterSeconds → rateLimited, no retry")
    func rateLimited() async throws {
        let fixture = try Fixture.data("error_envelope_rate_limited")
        StubURLProtocol.state.enqueue(.init(status: 429, body: fixture))

        let client = makeClient()
        let error = await llmError {
            let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: [ChatMessage(role: .user, content: "hi")]))
        }
        #expect(error == .rateLimited(retryAfter: 3600))
        #expect(StubURLProtocol.state.requestCount == 1)
    }

    @Test("401 → unauthorized")
    func unauthorized() async throws {
        StubURLProtocol.state.enqueue(.init(status: 401, body: envelope("unauthorized", message: "未知设备")))
        let client = makeClient(store: InMemoryCredentialStore())
        let error = await llmError {
            let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: []))
        }
        #expect(error == .unauthorized)
        let sent = try #require(StubURLProtocol.state.request(at: 0))
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("upstream_refusal → upstreamRefusal, never retried")
    func refusal() async throws {
        StubURLProtocol.state.enqueue(.init(status: 422, body: envelope("upstream_refusal")))
        let client = makeClient()
        let error = await llmError {
            let _: FoodRecognitionResultDTO = try await client.post(ProxyRoute.foodParseText, FoodParseTextRequest(text: "x"))
        }
        #expect(error == .upstreamRefusal)
        #expect(StubURLProtocol.state.requestCount == 1)
    }

    @Test("retryable upstream_error is retried exactly once")
    func retryOnce() async throws {
        StubURLProtocol.state.enqueue(.init(status: 502, body: envelope("upstream_error", retryable: true)))
        StubURLProtocol.state.enqueue(.init(status: 200, body: Data(#"{"replyZH":"ok","suggestions":[],"safetyFlags":[]}"#.utf8)))
        let client = makeClient()
        let response: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: [ChatMessage(role: .user, content: "hi")]))
        #expect(response.replyZH == "ok")
        #expect(StubURLProtocol.state.requestCount == 2)

        StubURLProtocol.state.reset()
        StubURLProtocol.state.enqueue(.init(status: 502, body: envelope("upstream_error", retryable: true)))
        StubURLProtocol.state.enqueue(.init(status: 502, body: envelope("upstream_error", retryable: true)))
        let error = await llmError {
            let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: []))
        }
        #expect(error == .upstream(retryable: true))
        #expect(StubURLProtocol.state.requestCount == 2)
    }

    @Test("non-envelope failures map by status; undecodable 2xx → decoding")
    func statusFallbacks() async throws {
        StubURLProtocol.state.enqueue(.init(status: 413, body: Data("too big".utf8), headers: ["Content-Type": "text/plain"]))
        let client = makeClient()
        let tooLarge = await llmError {
            let _: FoodRecognitionResultDTO = try await client.post(ProxyRoute.foodRecognize, FoodParseTextRequest(text: "x"))
        }
        #expect(tooLarge == .imageTooLarge)

        StubURLProtocol.state.enqueue(.init(status: 200, body: Data("{\"nope\":1}".utf8)))
        let decoding = await llmError {
            let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: []))
        }
        if case .decoding = decoding {} else { Issue.record("expected decoding, got \(String(describing: decoding))") }

        #expect(ProxyClient.mapFailure(status: 429, data: Data(), headers: ["Retry-After": "12"]) == .rateLimited(retryAfter: 12))
        #expect(ProxyClient.mapFailure(status: 503, data: Data(), headers: [:]) == .providerUnavailable)
        #expect(ProxyClient.mapFailure(status: 500, data: Data(), headers: [:]) == .upstream(retryable: true))
    }

    @Test("register stores the token and later calls use it")
    func register() async throws {
        StubURLProtocol.state.enqueue(.init(status: 200, body: Data(#"{"deviceToken":"tok_new","deviceId":"dev_1"}"#.utf8)))
        StubURLProtocol.state.enqueue(.init(status: 200, body: Data(#"{"replyZH":"ok","suggestions":[],"safetyFlags":[]}"#.utf8)))
        let store = InMemoryCredentialStore()
        let client = makeClient(store: store)
        #expect(client.isRegistered == false)

        let response = try await client.register(inviteCode: "invite", deviceName: "iPhone 17")
        #expect(response.deviceId == "dev_1")
        #expect(try store.token() == "tok_new")
        #expect(client.isRegistered)

        let first = try #require(StubURLProtocol.state.request(at: 0))
        #expect(first.request.url?.path == "/v1/devices/register")
        #expect(first.request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try Fixture.json(try #require(first.body))
        #expect(body["inviteCode"] as? String == "invite")
        #expect(body["platform"] as? String == "ios")

        let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: []))
        let second = try #require(StubURLProtocol.state.request(at: 1))
        #expect(second.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_new")

        try store.clear()
        #expect(try store.token() == nil)
    }

    @Test("DomesticProvider sends the backend hint, and throws providerUnavailable when unconfigured")
    func domestic() async throws {
        let unconfigured = DomesticProvider(baseURL: nil, credentials: InMemoryCredentialStore(), clientHeader: "ios")
        #expect(unconfigured.isConfigured == false)
        #expect(unconfigured.id == .domestic)
        let error = await llmError { _ = try await unconfigured.chat(CoachChatRequest(messages: [])) }
        #expect(error == .providerUnavailable)
        #expect(StubURLProtocol.state.requestCount == 0)

        StubURLProtocol.state.enqueue(.init(status: 200, body: Data(#"{"replyZH":"ok","suggestions":[],"safetyFlags":[]}"#.utf8)))
        let configured = DomesticProvider(client: makeClient())
        _ = try await configured.chat(CoachChatRequest(messages: [ChatMessage(role: .user, content: "hi")]))
        let sent = try #require(StubURLProtocol.state.request(at: 0))
        #expect(sent.request.value(forHTTPHeaderField: "X-Setmio-Backend") == "domestic")
    }

    @Test("transport failure → network, retried once")
    func networkFailure() async throws {
        // Empty queue: the stub fails the request.
        let client = makeClient()
        let error = await llmError {
            let _: CoachChatResponse = try await client.post(ProxyRoute.coachChat, CoachChatRequest(messages: []))
        }
        if case .network = error {} else { Issue.record("expected network, got \(String(describing: error))") }
        #expect(StubURLProtocol.state.requestCount == 2)
    }
}
