import Foundation

@testable import SwiftyNetwork

struct TestUser: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let email: String
}

struct TestEndpoint: NetworkEndpoint {
    let baseURL = "https://api.test.com"
    var path: String { "/users/123" }
    var method: HTTPMethod { .get }
}

final class TestURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responsesById = [String: [TestURLProtocol.Response]]()
    private var lastRequestHeadersById = [String: [String: String]?]()

    func setResponses(_ r: [TestURLProtocol.Response], for id: String) {
        lock.lock()
        defer { lock.unlock() }
        responsesById[id] = r
    }

    func dequeueResponse(for id: String?) -> TestURLProtocol.Response? {
        lock.lock()
        defer { lock.unlock() }
        let key = id ?? "__default"
        guard var arr = responsesById[key], !arr.isEmpty else { return nil }
        let resp = arr.removeFirst()
        responsesById[key] = arr
        return resp
    }

    func setLastRequestHeaders(_ h: [String: String]?, for id: String?) {
        lock.lock()
        defer { lock.unlock() }
        lastRequestHeadersById[id ?? "__default"] = h
    }

    func getLastRequestHeaders(for id: String?) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestHeadersById[id ?? "__default"] ?? nil
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responsesById.removeAll()
        lastRequestHeadersById.removeAll()
    }
}

final class TestURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data?
        let expectedAuthorization: String?
        let error: Error?
        let delay: TimeInterval

        /// Creates a successful response with the given data.
        static func success(_ data: Data, statusCode: Int = 200, delay: TimeInterval = 0) -> Response {
            Response(statusCode: statusCode, data: data, expectedAuthorization: nil, error: nil, delay: delay)
        }

        /// Creates a response with a specific status code.
        static func status(_ code: Int, data: Data = Data(), delay: TimeInterval = 0) -> Response {
            Response(statusCode: code, data: data, expectedAuthorization: nil, error: nil, delay: delay)
        }

        /// Creates a failure response with an error.
        static func failure(_ error: Error, delay: TimeInterval = 0) -> Response {
            Response(statusCode: 0, data: nil, expectedAuthorization: nil, error: error, delay: delay)
        }
    }
    private static let state = TestURLProtocolState()

    static func setResponses(_ r: [Response], for id: String? = nil) { state.setResponses(r, for: id ?? "__default") }
    static func dequeueResponse(for id: String?) -> Response? { state.dequeueResponse(for: id) }
    static func setLastRequestHeaders(_ h: [String: String]?, for id: String? = nil) {
        state.setLastRequestHeaders(h, for: id)
    }
    static func getLastRequestHeaders(for id: String? = nil) -> [String: String]? {
        state.getLastRequestHeaders(for: id)
    }
    static func reset() { state.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let testId = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "test-id" })?
                .value
        }
        TestURLProtocol.setLastRequestHeaders(request.allHTTPHeaderFields, for: testId)
        guard let resp = Self.dequeueResponse(for: testId) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if resp.delay > 0 {
            Thread.sleep(forTimeInterval: resp.delay)
        }
        if let error = resp.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: resp.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if let data = resp.data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func makeEndpointWithTestId(_ id: String) -> some NetworkEndpoint {
    struct E: NetworkEndpoint {
        let testId: String
        init(testId: String) { self.testId = testId }
        let baseURL = "https://api.test.com"
        var path: String { "/users/123" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
    }
    return E(testId: id)
}

func makeTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// A single-use rendezvous point: `wait()` suspends until `open()` is called
/// (or returns immediately if `open()` already happened). Used to force a
/// deterministic interleaving between a fake network call and a test's
/// subsequent actions, instead of relying on a race won by a fixed delay.
actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// A scriptable ``APIClient`` for testing ``MutationQueue`` without going
/// through `URLSession`. Each call to `request` consumes the next queued
/// outcome and records the endpoint's path for later assertions.
actor FakeAPIClient: APIClient {
    enum Outcome {
        case success
        case failure(any Error & Sendable)
    }

    private var outcomes: [Outcome]
    private let delayNanoseconds: UInt64
    private let gate: Gate?
    /// Per-call gates, indexed by 0-based call number. Lets a test block a
    /// *specific* call (e.g. only the second attempt) rather than every call,
    /// which a single shared `Gate` can't express once it's been opened once.
    private let gatesByCallIndex: [Int: Gate]
    private(set) var callCount = 0
    private(set) var recordedRequests: [MutationRequest] = []

    init(outcomes: [Outcome], delayNanoseconds: UInt64 = 0, gate: Gate? = nil, gatesByCallIndex: [Int: Gate] = [:]) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
        self.gate = gate
        self.gatesByCallIndex = gatesByCallIndex
    }

    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let callIndex = callCount
        callCount += 1
        recordedRequests.append(MutationRequest(endpoint: endpoint))

        if let gate {
            await gate.wait()
        }
        if let perCallGate = gatesByCallIndex[callIndex] {
            await perCallGate.wait()
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            guard let value = EmptyResponse() as? T else { throw NetworkError.invalidData }
            return value
        case .failure(let error):
            throw error
        }
    }
}

/// Consumes exactly `count` events from an `AsyncStream`, or fewer if the
/// stream never yields that many. Bounded so a failing assertion doesn't
/// hang the test indefinitely.
func collectEvents<T: Sendable>(_ stream: AsyncStream<T>, count: Int) async -> [T] {
    var results: [T] = []
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<count {
        guard let event = await iterator.next() else { break }
        results.append(event)
    }
    return results
}

/// Consumes events from an `AsyncStream` until `predicate` matches, giving up
/// after `maxCount` events so a failing assertion doesn't hang the test
/// indefinitely. Returns the matching event, or `nil` if it never arrived.
func firstEvent<T: Sendable>(
    in stream: AsyncStream<T>,
    maxCount: Int = 50,
    where predicate: (T) -> Bool
) async -> T? {
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<maxCount {
        guard let event = await iterator.next() else { return nil }
        if predicate(event) { return event }
    }
    return nil
}

public actor TestAuthorizationProvider: AuthorizationProvider {
    private var currentAuth: AuthorizationType
    private let refreshResult: Bool
    private let refreshedAuth: AuthorizationType?
    private(set) var refreshCallCount = 0

    public init(
        current: AuthorizationType,
        refreshResult: Bool,
        refreshedAuthorization: AuthorizationType? = nil
    ) {
        self.currentAuth = current
        self.refreshResult = refreshResult
        self.refreshedAuth = refreshedAuthorization
    }

    public func currentAuthorization() async -> AuthorizationType {
        currentAuth
    }

    public func refreshAuthorizationIfNeeded() async -> Bool {
        refreshCallCount += 1
        if refreshResult, let refreshedAuth {
            currentAuth = refreshedAuth
        }
        return refreshResult
    }
}

/// Records every ``NetworkInstrumentation`` event for later assertions.
actor FakeNetworkInstrumentation: NetworkInstrumentation {
    private(set) var started: [NetworkRequestAttempt] = []
    private(set) var retried: [NetworkRequestAttempt] = []
    private(set) var completed: [NetworkRequestCompletion] = []
    private(set) var failed: [NetworkRequestFailure] = []

    func requestStarted(_ event: NetworkRequestAttempt) async { started.append(event) }
    func requestRetried(_ event: NetworkRequestAttempt) async { retried.append(event) }
    func requestCompleted(_ event: NetworkRequestCompletion) async { completed.append(event) }
    func requestFailed(_ event: NetworkRequestFailure) async { failed.append(event) }
}
