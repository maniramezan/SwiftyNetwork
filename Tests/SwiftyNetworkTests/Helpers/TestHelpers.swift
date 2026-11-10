import Foundation
import TestCommons

@testable @_spi(Testing) import SwiftyNetwork

/// How long a test waits for something that should happen before failing instead of hanging.
///
/// A wait returns as soon as its condition holds, so this only bounds a broken test. It is generous
/// because shared CI simulators can stall a single test for tens of seconds; never use it to assert
/// that something does not happen.
let testTimeout: Duration = .seconds(60)

/// Records the waits a `NetworkClient` requests and returns at once, so tests can assert retry
/// and refresh delays exactly instead of timing them.
actor SleepRecorder {
    /// Requested waits, in order.
    private(set) var durations: [Duration] = []

    /// Pass as `NetworkClient(configuration:sleeper:)`'s `sleeper`.
    nonisolated var sleeper: @Sendable (Duration) async throws -> Void {
        { duration in await self.record(duration) }
    }

    private func record(_ duration: Duration) {
        durations.append(duration)
    }
}

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

func makeEndpointWithTestId(_ id: String, method: HTTPMethod = .get) -> some NetworkEndpoint {
    struct E: NetworkEndpoint {
        let testId: String
        let method: HTTPMethod
        init(testId: String, method: HTTPMethod) {
            self.testId = testId
            self.method = method
        }
        let baseURL = "https://api.test.com"
        var path: String { "/users/123" }
        var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
    }
    return E(testId: id, method: method)
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

    func response<T: Decodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> DecodedResponse<T> {
        let response = try await responder.respond(to: MutationRequest(endpoint: endpoint))
        guard let value = response as? T else {
            throw NetworkError.decodingFailed(underlying: URLError(.cannotDecodeContentData))
        }
        return DecodedResponse(value: value)
    }
}

/// Collects up to `count` events, stopping early if the stream finishes or `timeout` expires.
///
/// Backed by `observeStream`, so a stalled stream cannot hang the test. A timeout finishes the
/// stream, so only reuse a stream after this returns `count` events.
func collectEvents<T: Sendable>(
    _ stream: AsyncStream<T>, count: Int, timeout: Duration = testTimeout
) async -> [T] {
    (try? await observeStream(stream, maxCount: count, timeout: timeout).values) ?? []
}

/// Returns the first event matching `predicate`, or `nil` after `maxCount` events, the end of
/// the stream, or `timeout`.
func firstEvent<T: Sendable>(
    in stream: AsyncStream<T>,
    maxCount: Int = 50,
    timeout: Duration = testTimeout,
    where predicate: @escaping @Sendable (T) -> Bool
) async -> T? {
    guard let observation = try? await observeStream(stream, maxCount: maxCount, timeout: timeout, until: predicate),
        observation.end == .matched
    else { return nil }
    return observation.values.last
}

typealias FakeNetworkInstrumentation = NetworkInstrumentationRecorder
