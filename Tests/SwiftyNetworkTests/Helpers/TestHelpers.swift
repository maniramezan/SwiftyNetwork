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
    private var _responsesById = [String: [TestURLProtocol.Response]]()
    private var _lastRequestHeadersById = [String: [String: String]?]()
    private let lock = DispatchQueue(label: "TestURLProtocol.state.lock")

    func setResponses(_ r: [TestURLProtocol.Response], for id: String) {
        lock.sync { _responsesById[id] = r }
    }

    func dequeueResponse(for id: String?) -> TestURLProtocol.Response? {
        return lock.sync {
            let key = id ?? "__default"
            guard var arr = _responsesById[key], !arr.isEmpty else { return nil }
            let resp = arr.removeFirst()
            _responsesById[key] = arr
            return resp
        }
    }

    func setLastRequestHeaders(_ h: [String: String]?, for id: String?) {
        lock.sync { _lastRequestHeadersById[id ?? "__default"] = h }
    }

    func getLastRequestHeaders(for id: String?) -> [String: String]? {
        return lock.sync { _lastRequestHeadersById[id ?? "__default"] ?? nil }
    }

    func reset() {
        lock.sync {
            _responsesById.removeAll()
            _lastRequestHeadersById.removeAll()
        }
    }
}

final class TestURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data?
        let expectedAuthorization: String?
        let error: Error?

        /// Creates a successful response with the given data.
        static func success(_ data: Data, statusCode: Int = 200) -> Response {
            Response(statusCode: statusCode, data: data, expectedAuthorization: nil, error: nil)
        }

        /// Creates a response with a specific status code.
        static func status(_ code: Int, data: Data = Data()) -> Response {
            Response(statusCode: code, data: data, expectedAuthorization: nil, error: nil)
        }

        /// Creates a failure response with an error.
        static func failure(_ error: Error) -> Response {
            Response(statusCode: 0, data: nil, expectedAuthorization: nil, error: error)
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
