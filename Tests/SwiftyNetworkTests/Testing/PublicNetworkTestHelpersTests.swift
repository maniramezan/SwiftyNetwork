import Foundation
import SwiftyNetwork
import SwiftyNetworkTesting
import Testing

@Suite("Public network test helpers integration")
struct PublicNetworkTestHelpersTests {
    @Test("Repeated 401 responses exhaust the refresh budget and close the retried attempt")
    func repeatedUnauthorizedResponses() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401), .status(401)], for: id)
        let provider = SwiftyNetworkTesting.TestAuthorizationProvider(
            current: .bearer(token: "original"), refreshResult: true,
            refreshedAuthorization: .bearer(token: "refreshed")
        )
        let recorder = NetworkInstrumentationRecorder()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session, authorizationProvider: provider,
                maxAuthRefreshAttempts: 1, retryDelay: 0, instrumentation: recorder
            ))

        await #expect {
            try await client.request(makeEndpointWithTestId(id), responseType: TestUser.self)
        } throws: { error in
            (error as? NetworkError)?.classification == .unauthorized
        }

        #expect(await provider.refreshCallCount == 1)
        #expect(await provider.rejectedAuthorizations == [.bearer(token: "original")])
        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == "Bearer refreshed")
        let started = await recorder.started
        let retried = await recorder.retried
        let failed = await recorder.failed
        #expect(started.map(\.attempt) == [1, 2])
        #expect(retried.map(\.attempt) == [2])
        #expect(failed.map(\.attempt) == [2])
        #expect(failed.first?.error.classification == .unauthorized)
        #expect(await recorder.completed.isEmpty)
        let startedIDs = Set(started.map(\.requestID))
        let retriedIDs = Set(retried.map(\.requestID))
        let failedIDs = Set(failed.map(\.requestID))
        #expect(startedIDs.count == 1)
        #expect(retriedIDs == startedIDs)
        #expect(failedIDs == startedIDs)
    }

    @Test("A failed refresh retains the rejected credential and never starts another attempt")
    func failedRefreshKeepsOriginalAuthorization() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401)], for: id)
        let provider = SwiftyNetworkTesting.TestAuthorizationProvider(
            current: .bearer(token: "original"), refreshResult: false,
            refreshedAuthorization: .bearer(token: "must-not-be-used")
        )
        let recorder = NetworkInstrumentationRecorder()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session, authorizationProvider: provider,
                retryDelay: 0, instrumentation: recorder
            ))

        await #expect {
            try await client.request(makeEndpointWithTestId(id), responseType: TestUser.self)
        } throws: { error in
            (error as? NetworkError)?.classification == .authorizationRefreshFailed
        }

        #expect(await provider.currentAuthorization() == .bearer(token: "original"))
        #expect(await provider.refreshCallCount == 1)
        #expect(await provider.rejectedAuthorizations == [.bearer(token: "original")])
        let started = try #require(await recorder.started.first)
        let failure = try #require(await recorder.failed.first)
        #expect(await recorder.started.count == 1)
        #expect(await recorder.failed.count == 1)
        #expect(failure.requestID == started.requestID)
        #expect(failure.attempt == 1)
        #expect(failure.error.classification == .authorizationRefreshFailed)
        #expect(await recorder.retried.isEmpty)
        #expect(await recorder.completed.isEmpty)
    }

    @Test("Malformed JSON after a refresh records decoding failure rather than completion")
    func decodingFailureAfterRefresh() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401), .success(Data("not-json".utf8))], for: id)
        let provider = SwiftyNetworkTesting.TestAuthorizationProvider(
            current: .bearer(token: "original"), refreshResult: true,
            refreshedAuthorization: .bearer(token: "refreshed")
        )
        let recorder = NetworkInstrumentationRecorder()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session, authorizationProvider: provider,
                retryDelay: 0, instrumentation: recorder
            ))

        await #expect {
            try await client.request(makeEndpointWithTestId(id), responseType: TestUser.self)
        } throws: { error in
            (error as? NetworkError)?.classification == .decodingFailed
        }

        let started = await recorder.started
        let retry = try #require(await recorder.retried.first)
        let failure = try #require(await recorder.failed.first)
        #expect(started.map(\.attempt) == [1, 2])
        #expect(await recorder.failed.count == 1)
        #expect(await recorder.retried.count == 1)
        #expect(failure.attempt == 2)
        #expect(failure.error.classification == .decodingFailed)
        #expect(started.allSatisfy { $0.requestID == failure.requestID })
        #expect(retry.requestID == failure.requestID)
        #expect(await recorder.completed.isEmpty)
    }

    @Test("One public recorder correlates concurrent successful and failed requests independently")
    func concurrentMixedOutcomes() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let successID = UUID().uuidString
        let failureID = UUID().uuidString
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        stub.setResponses([.success(try JSONEncoder().encode(user))], for: successID)
        stub.setResponses([.status(500)], for: failureID)
        let recorder = NetworkInstrumentationRecorder()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session, instrumentation: recorder
            ))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let response = try await client.request(
                    makeEndpointWithTestId(successID), responseType: TestUser.self
                )
                #expect(response == user)
            }
            group.addTask {
                await #expect {
                    try await client.request(makeEndpointWithTestId(failureID), responseType: TestUser.self)
                } throws: { error in
                    (error as? NetworkError)?.classification == .serverError(statusCode: 500)
                }
            }
            try await group.waitForAll()
        }

        let started = await recorder.started
        let completed = await recorder.completed
        let failed = await recorder.failed
        #expect(started.count == 2)
        #expect(Set(started.map(\.requestID)).count == 2)
        #expect(completed.count == 1)
        #expect(failed.count == 1)
        let startedIDs = Set(started.map(\.requestID))
        let completedIDs = Set(completed.map(\.requestID))
        let failedIDs = Set(failed.map(\.requestID))
        #expect(startedIDs == completedIDs.union(failedIDs))
        let completion = try #require(completed.first)
        let failure = try #require(failed.first)
        #expect(completion.requestID != failure.requestID)
        #expect(completion.statusCode == 200)
        #expect(failure.error.classification == .serverError(statusCode: 500))
        #expect(started.first { $0.requestID == completion.requestID }?.url == completion.url)
        #expect(started.first { $0.requestID == failure.requestID }?.url == failure.url)
        #expect(completion.url.query?.contains(successID) == true)
        #expect(failure.url.query?.contains(failureID) == true)
        #expect(await recorder.retried.isEmpty)
    }
}
