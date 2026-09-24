import Foundation
import SwiftyNetwork

/// A scriptable `APIClient` for unit tests and SwiftUI previews.
///
/// Stub responses per HTTP method and path, then inject the mock wherever the
/// code under test accepts `any APIClient` or a `NetworkDataSource` (for
/// example `GenericRepository` or `MutationQueue`). Every request is recorded
/// so tests can assert on what was sent.
///
/// Responses for a route are consumed in order; the last one repeats for any
/// further calls. A request with no stub throws ``UnstubbedRequestError``
/// unless a fallback is set with ``setFallback(_:)``.
///
/// Example:
/// ```swift
/// let client = MockAPIClient()
/// try await client.stub(.get, "/users/1", returning: User(id: "1", name: "Ada"))
/// await client.stub(.post, "/likes", with: .failure(NetworkError.timeout), .empty)
///
/// let service = UserService(client: client)
/// let user = try await service.user(id: "1")
///
/// let sent = await client.requests(to: "/users/1")
/// #expect(sent.count == 1)
/// ```
public actor MockAPIClient: NetworkDataSource {
    /// A scripted outcome for a stubbed route.
    public enum Response: Sendable {
        /// JSON bytes decoded into the requested type with the mock's decoder.
        /// Empty data satisfies requests for `EmptyResponse`.
        case json(Data)
        /// A value returned as-is when it matches the requested type.
        case value(any Sendable)
        /// An error thrown to the caller.
        case failure(any Error & Sendable)

        /// A successful response with no body.
        public static let empty = Response.json(Data())
    }

    /// Thrown when a request matches no stub and no fallback is set.
    public struct UnstubbedRequestError: Error, Sendable, CustomStringConvertible {
        /// The HTTP method of the unmatched request.
        public let method: HTTPMethod
        /// The path of the unmatched request.
        public let path: String

        public var description: String { "No stub for \(method.rawValue) \(path)" }
    }

    /// Thrown when a ``Response/value(_:)`` stub doesn't match the requested type.
    public struct TypeMismatchError: Error, Sendable, CustomStringConvertible {
        /// The requested response type.
        public let expected: String
        /// The type of the stubbed value.
        public let actual: String

        public var description: String { "Stubbed \(actual) cannot be returned as \(expected)" }
    }

    private struct Route: Hashable {
        let method: HTTPMethod
        let path: String
    }

    private struct DecodingFailure: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    private let decoder: JSONDecoder
    private var responsesByRoute: [Route: [Response]] = [:]
    private var fallback: Response?

    /// Every request received, in order.
    public private(set) var recordedRequests: [RecordedRequest] = []

    /// Creates a mock client with no stubs.
    ///
    /// - Parameter decoder: Decodes ``Response/json(_:)`` stubs. Match the
    ///   decoder your production `NetworkClientConfiguration` uses.
    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    // MARK: - Stubbing

    /// Queues responses for `method` and `path`, replacing any existing stub for that route.
    ///
    /// - Parameters:
    ///   - method: The HTTP method to match.
    ///   - path: The endpoint path to match exactly, as declared by the endpoint.
    ///   - responses: Outcomes returned in order; the last one repeats.
    public func stub(_ method: HTTPMethod, _ path: String, with responses: Response...) {
        responsesByRoute[Route(method: method, path: path)] = responses
    }

    /// Stubs a route with a value encoded as JSON, so decoding runs just as it
    /// would against a real response.
    ///
    /// - Parameters:
    ///   - method: The HTTP method to match.
    ///   - path: The endpoint path to match exactly.
    ///   - value: The value to encode and later decode as the response body.
    ///   - encoder: The encoder used to produce the JSON body.
    /// - Throws: Any error thrown while encoding `value`.
    public func stub<Value: Encodable>(
        _ method: HTTPMethod,
        _ path: String,
        returning value: Value,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let data = try encoder.encode(value)
        responsesByRoute[Route(method: method, path: path)] = [.json(data)]
    }

    /// Sets the response used for requests that match no stub, or `nil` to
    /// throw ``UnstubbedRequestError`` instead (the default).
    ///
    /// - Parameter response: The fallback outcome.
    public func setFallback(_ response: Response?) {
        fallback = response
    }

    /// Removes every stub, the fallback, and all recorded requests.
    public func reset() {
        responsesByRoute.removeAll()
        fallback = nil
        recordedRequests.removeAll()
    }

    // MARK: - Inspection

    /// Recorded requests whose path equals `path`.
    ///
    /// - Parameter path: The endpoint path to filter by.
    /// - Returns: Matching requests, in the order they were received.
    public func requests(to path: String) -> [RecordedRequest] {
        recordedRequests.filter { $0.path == path }
    }

    // MARK: - APIClient

    /// Records the request and returns the next scripted outcome for its route.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint being requested.
    ///   - responseType: The expected response type.
    /// - Returns: The stubbed value decoded or cast to `responseType`.
    /// - Throws: The stubbed error, ``UnstubbedRequestError``,
    ///   ``TypeMismatchError``, or `NetworkError.decodingFailed(underlying:)`.
    public func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        recordedRequests.append(RecordedRequest(endpoint))

        switch try nextResponse(for: Route(method: endpoint.method, path: endpoint.path)) {
        case .failure(let error):
            throw error
        case .value(let value):
            guard let typed = value as? T else {
                throw TypeMismatchError(
                    expected: String(describing: T.self),
                    actual: String(describing: type(of: value))
                )
            }
            return typed
        case .json(let data):
            if data.isEmpty, let empty = EmptyResponse() as? T {
                return empty
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let failure = DecodingFailure(description: String(describing: error))
                throw NetworkError.decodingFailed(underlying: failure)
            }
        }
    }

    private func nextResponse(for route: Route) throws -> Response {
        guard var queued = responsesByRoute[route], let next = queued.first else {
            if let fallback { return fallback }
            throw UnstubbedRequestError(method: route.method, path: route.path)
        }
        if queued.count > 1 {
            queued.removeFirst()
            responsesByRoute[route] = queued
        }
        return next
    }
}
