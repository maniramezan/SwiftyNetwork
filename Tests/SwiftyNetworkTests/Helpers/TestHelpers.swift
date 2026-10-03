import Foundation
import SwiftyNetworkTesting
import TestCommons

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

/// A scriptable ``APIClient`` for testing ``MutationQueue`` without going
/// through `URLSession`. Each call to `request` consumes the next queued
/// outcome and records the endpoint's path for later assertions.
actor FakeAPIClient: APIClient {
    enum Outcome {
        case success
        case failure(any Error & Sendable)
    }

    private let responder: ScriptedResponder<MutationRequest, EmptyResponse>

    var callCount: Int { get async { await responder.callCount } }
    var recordedRequests: [MutationRequest] { get async { await responder.requests } }

    init(outcomes: [Outcome]) {
        responder = ScriptedResponder(
            outcomes.map { outcome in
                switch outcome {
                case .success: .success(EmptyResponse())
                case .failure(let error): .failure(error)
                }
            }, fallback: .success(EmptyResponse()))
    }

    func hold(call: Int) async -> AsyncGate {
        await responder.hold(call: call)
    }

    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let response = try await responder.respond(to: MutationRequest(endpoint: endpoint))
        guard let value = response as? T else {
            throw NetworkError.invalidData
        }
        return value
    }
}

/// Collects up to `count` events, stopping early if the stream finishes or `timeout` expires.
///
/// Backed by `observeStream`, so a stalled stream cannot hang the test. A timeout finishes the
/// stream, so only reuse a stream after this returns `count` events.
func collectEvents<T: Sendable>(
    _ stream: AsyncStream<T>, count: Int, timeout: Duration = .seconds(5)
) async -> [T] {
    (try? await observeStream(stream, maxCount: count, timeout: timeout).values) ?? []
}

/// Returns the first event matching `predicate`, or `nil` after `maxCount` events, the end of
/// the stream, or `timeout`.
func firstEvent<T: Sendable>(
    in stream: AsyncStream<T>,
    maxCount: Int = 50,
    timeout: Duration = .seconds(5),
    where predicate: @escaping @Sendable (T) -> Bool
) async -> T? {
    guard let observation = try? await observeStream(stream, maxCount: maxCount, timeout: timeout, until: predicate),
        observation.end == .matched
    else { return nil }
    return observation.values.last
}

typealias TestAuthorizationProvider = SwiftyNetworkTesting.TestAuthorizationProvider
typealias FakeNetworkInstrumentation = NetworkInstrumentationRecorder
