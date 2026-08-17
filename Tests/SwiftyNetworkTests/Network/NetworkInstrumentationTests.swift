import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("NetworkClient Instrumentation Tests")
struct NetworkInstrumentationTests {

    @Test("A successful request emits requestStarted then requestCompleted with matching requestID")
    func successfulRequestEmitsStartedThenCompleted() async throws {
        let testId = "instrumentation-success"
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let configuration = NetworkClientConfiguration(session: session, instrumentation: instrumentation)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        TestURLProtocol.setResponses([.success(try JSONEncoder().encode(user))], for: testId)

        _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let started = await instrumentation.started
        let completed = await instrumentation.completed
        #expect(await instrumentation.failed.isEmpty)
        #expect(await instrumentation.retried.isEmpty)

        let startedEvent = try #require(started.first)
        let completedEvent = try #require(completed.first)
        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(startedEvent.requestID == completedEvent.requestID)
        #expect(startedEvent.attempt == 1)
        #expect(completedEvent.attempt == 1)
        #expect(completedEvent.statusCode == 200)
        #expect(completedEvent.duration >= 0)
        #expect(completedEvent.method == .get)
    }

    @Test("A server error emits requestStarted then requestFailed with the classified error")
    func serverErrorEmitsFailed() async {
        let testId = "instrumentation-server-error"
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let configuration = NetworkClientConfiguration(session: session, instrumentation: instrumentation)
        let client = NetworkClient(configuration: configuration)
        TestURLProtocol.setResponses([.status(500)], for: testId)

        _ = try? await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let started = await instrumentation.started
        let failed = await instrumentation.failed
        #expect(await instrumentation.completed.isEmpty)
        #expect(started.count == 1)
        #expect(failed.count == 1)
        #expect(failed.first?.error.classification == .serverError(statusCode: 500))
        #expect(failed.first?.requestID == started.first?.requestID)
        #expect((failed.first?.duration ?? -1) >= 0)
    }

    @Test("A transport failure emits requestFailed with the mapped NetworkError classification")
    func transportFailureEmitsFailed() async {
        let testId = "instrumentation-transport-failure"
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let configuration = NetworkClientConfiguration(session: session, instrumentation: instrumentation)
        let client = NetworkClient(configuration: configuration)
        TestURLProtocol.setResponses([.failure(URLError(.notConnectedToInternet))], for: testId)

        _ = try? await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let failed = await instrumentation.failed
        #expect(failed.count == 1)
        #expect(failed.first?.error.classification == .noConnection)
    }

    @Test("A 401 that successfully refreshes emits requestRetried and a second attempt sharing the requestID")
    func successfulRefreshEmitsRetriedAndSecondAttempt() async throws {
        let testId = "instrumentation-refresh-success"
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            retryDelay: 0,
            instrumentation: instrumentation
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        TestURLProtocol.setResponses(
            [.status(401), .success(try JSONEncoder().encode(user))],
            for: testId
        )

        _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let started = await instrumentation.started
        let retried = await instrumentation.retried
        let completed = await instrumentation.completed
        #expect(await instrumentation.failed.isEmpty)

        #expect(started.map(\.attempt) == [1, 2])
        #expect(retried.map(\.attempt) == [2])
        #expect(completed.map(\.attempt) == [2])

        let requestIDs = Set(started.map(\.requestID) + retried.map(\.requestID) + completed.map(\.requestID))
        #expect(requestIDs.count == 1)
    }

    @Test("A 401 that fails to refresh emits requestFailed without requestRetried")
    func failedRefreshEmitsFailedWithoutRetried() async {
        let testId = "instrumentation-refresh-failure"
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let provider = TestAuthorizationProvider(current: .bearer(token: "expired"), refreshResult: false)
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            retryDelay: 0,
            instrumentation: instrumentation
        )
        let client = NetworkClient(configuration: configuration)
        TestURLProtocol.setResponses([.status(401)], for: testId)

        _ = try? await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let failed = await instrumentation.failed
        #expect(await instrumentation.retried.isEmpty)
        #expect(failed.count == 1)
        #expect(failed.first?.error.classification == .authorizationRefreshFailed)
    }

    @Test("Independent requests receive distinct requestIDs")
    func independentRequestsHaveDistinctIDs() async throws {
        let session = makeTestSession()
        let instrumentation = FakeNetworkInstrumentation()
        let configuration = NetworkClientConfiguration(session: session, instrumentation: instrumentation)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let encoded = try JSONEncoder().encode(user)
        TestURLProtocol.setResponses([.success(encoded)], for: "instrumentation-distinct-a")
        TestURLProtocol.setResponses([.success(encoded)], for: "instrumentation-distinct-b")

        _ = try await client.request(makeEndpointWithTestId("instrumentation-distinct-a"), responseType: TestUser.self)
        _ = try await client.request(makeEndpointWithTestId("instrumentation-distinct-b"), responseType: TestUser.self)

        let started = await instrumentation.started
        #expect(started.count == 2)
        #expect(started[0].requestID != started[1].requestID)
    }

    @Test("A conformer that implements no methods uses the no-op defaults without crashing")
    func defaultNoOpImplementationsAreUsable() async throws {
        struct MinimalInstrumentation: NetworkInstrumentation {}

        let testId = "instrumentation-minimal-conformer"
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session, instrumentation: MinimalInstrumentation())
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        TestURLProtocol.setResponses([.success(try JSONEncoder().encode(user))], for: testId)

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(response == user)
    }

    @Test("Without instrumentation configured, requests still succeed")
    func noInstrumentationConfiguredStillWorks() async throws {
        let testId = "instrumentation-none"
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        TestURLProtocol.setResponses([.success(try JSONEncoder().encode(user))], for: testId)

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(response == user)
    }
}
