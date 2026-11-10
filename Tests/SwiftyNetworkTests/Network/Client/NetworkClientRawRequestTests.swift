import Foundation
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("NetworkClient.sendAuthorized", .serialized)
struct NetworkClientRawRequestTests {
    private func makeRequest(_ id: String) -> URLRequest {
        URLRequest(url: URL(string: "https://api.test.com/stream?test-id=\(id)")!)
    }

    private func makeClient(
        stub: TestHTTPStub,
        provider: (any AuthorizationProvider)?,
        recorder: NetworkInstrumentationRecorder? = nil
    ) -> NetworkClient {
        NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                authRefreshDelay: .zero,
                instrumentation: recorder
            )
        )
    }

    private func readAll(_ bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes { data.append(byte) }
        } catch {}
        return data
    }

    @Test("Applies the provider's authorization and returns the stream on 2xx")
    func appliesAuthorization() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.success(Data("data: hi\n".utf8))], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "t"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        let result = try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
            try await session.bytes(for: request, delegate: delegate)
        }

        #expect(result.response.statusCode == 200)
        #expect(await readAll(result.payload) == Data("data: hi\n".utf8))
        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == "Bearer t")
        #expect(await provider.refreshCallCount == 0)
    }

    @Test("Without a provider the request is sent unchanged")
    func noProviderSendsUnchanged() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(204)], for: id)
        let client = makeClient(stub: stub, provider: nil)
        var request = makeRequest(id)
        request.setValue("Bearer caller", forHTTPHeaderField: "Authorization")

        _ = try await client.sendAuthorized(request) { request, session, delegate in
            try await session.data(for: request, delegate: delegate)
        }

        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == "Bearer caller")
    }

    @Test("A 401 refreshes once with the rejected authorization and replays with the new one")
    func refreshesOnceAndReplays() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401), .success(Data("ok".utf8))], for: id)
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "new")
        )
        let recorder = NetworkInstrumentationRecorder()
        let client = makeClient(stub: stub, provider: provider, recorder: recorder)

        let result = try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
            try await session.data(for: request, delegate: delegate)
        }

        #expect(result.payload == Data("ok".utf8))
        #expect(await provider.refreshCallCount == 1)
        #expect(await provider.rejectedAuthorizations == [.bearer(token: "old")])
        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == "Bearer new")
        #expect(await recorder.started.map(\.attempt) == [1, 2])
        #expect(await recorder.retried.map(\.attempt) == [2])
        #expect(await recorder.completed.map(\.statusCode) == [200])
    }

    @Test("A second 401 throws unauthorized after the refresh budget is spent")
    func secondUnauthorizedThrows() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401), .status(401)], for: id)
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "new")
        )
        let client = makeClient(stub: stub, provider: provider)

        await #expect {
            try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .unauthorized
        }
        #expect(await provider.refreshCallCount == 1)
    }

    @Test("A failed refresh throws authorizationRefreshFailed")
    func failedRefreshThrows() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401)], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "old"), refreshResult: false)
        let client = makeClient(stub: stub, provider: provider)

        await #expect {
            try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            guard case .authorizationRefreshFailed(let underlying) = error as? NetworkError else { return false }
            return underlying is TestAuthorizationProvider.RefreshFailed
        }
    }

    @Test("A provider that declines the refresh throws unauthorized without refreshing")
    func declinedRefreshThrows() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401)], for: id)
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            shouldRefresh: { _ in false }
        )
        let client = makeClient(stub: stub, provider: provider)

        await #expect {
            try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .unauthorized
        }
        #expect(await provider.refreshCallCount == 0)
    }

    @Test("errorBody supplies the 401 body to shouldRefreshAuthorization and to the thrown error")
    func errorBodyReachesProviderAndError() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401, data: Data("{\"code\":\"x\"}".utf8))], for: id)
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            shouldRefresh: { _ in false }
        )
        let client = makeClient(stub: stub, provider: provider)

        await #expect {
            try await client.sendAuthorized(
                makeRequest(id),
                errorBody: { (bytes: URLSession.AsyncBytes) in await readAll(bytes) },
                transport: { request, session, delegate in
                    try await session.bytes(for: request, delegate: delegate)
                }
            )
        } throws: { error in
            (error as? NetworkError)?.response?.body == Data("{\"code\":\"x\"}".utf8)
        }
        let inspected = await provider.inspectedResponses
        #expect(inspected.map(\.body) == [Data("{\"code\":\"x\"}".utf8)])
    }

    @Test("Other non-2xx statuses map to the same NetworkError cases as endpoint requests")
    func statusMapping() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(503, headers: ["Retry-After": "7"])], for: id)
        let client = makeClient(stub: stub, provider: nil)

        await #expect {
            try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            guard case .serverError(let response) = error as? NetworkError else { return false }
            return response.statusCode == 503 && response.retryAfter == .seconds(7)
        }
    }

    @Test("A provider that throws fails with authorizationUnavailable and nothing is sent")
    func unavailableAuthorization() async throws {
        struct SignedOut: Error {}
        struct Throwing: AuthorizationProvider {
            func currentAuthorization() async throws -> AuthorizationType { throw SignedOut() }
            func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}
        }
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = makeClient(stub: stub, provider: Throwing())

        await #expect {
            try await client.sendAuthorized(makeRequest("unavailable")) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .authorizationUnavailable
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("Transport failures map like endpoint requests")
    func transportFailureMapping() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.failure(URLError(.notConnectedToInternet))], for: id)
        let client = makeClient(stub: stub, provider: nil)

        await #expect {
            try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .noInternetConnection
        }
    }

    @Test("A request without a URL throws invalidURL")
    func missingURL() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = makeClient(stub: stub, provider: nil)

        await #expect {
            try await client.sendAuthorized(URLRequest(url: URL(string: "https://api.test.com")!).withoutURL()) {
                request, session, delegate in
                try await session.data(for: request, delegate: delegate)
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .invalidURL
        }
    }

    @Test("A cross-origin redirect drops the provider's credentials")
    func redirectStripsCredentials() async throws {
        let origin = "raw-origin-\(UUID().uuidString.lowercased()).test"
        let other = "raw-other-\(UUID().uuidString.lowercased()).test"
        let session = RedirectingURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            RedirectingURLProtocol.unregister([origin, other])
        }
        let start = try #require(URL(string: "https://\(origin)/stream"))
        let target = try #require(URL(string: "https://\(other)/stream"))
        RedirectingURLProtocol.register(.redirect(to: target), for: start)
        RedirectingURLProtocol.register(.ok(Data("ok".utf8)), for: target)
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: session,
                authorizationProvider: TestAuthorizationProvider(current: .bearer(token: "t"), refreshResult: true),
                authRefreshDelay: .zero
            )
        )

        let result = try await client.sendAuthorized(URLRequest(url: start)) { request, session, delegate in
            try await session.data(for: request, delegate: delegate)
        }

        #expect(result.payload == Data("ok".utf8))
        let sent = RedirectingURLProtocol.requests(forHost: origin)
        let redirected = RedirectingURLProtocol.requests(forHost: other)
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Cancelling the caller during the transport throws CancellationError and reports the failure")
    func cancellationThrowsCancellationError() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let recorder = NetworkInstrumentationRecorder()
        let client = makeClient(stub: stub, provider: nil, recorder: recorder)

        await #expect(throws: CancellationError.self) {
            _ = try await client.sendAuthorized(makeRequest("cancel")) { _, _, _ -> (Data, URLResponse) in
                // URLSession reports a cancelled task this way.
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        #expect(await recorder.started.count == 1)
        #expect(await recorder.failed.count == 1)
        #expect(await recorder.completed.isEmpty)
    }

    @Test("URLError.cancelled without task cancellation, as from a rejected pin, is an insecure connection")
    func rejectedPinIsInsecureConnection() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = makeClient(stub: stub, provider: nil)

        await #expect {
            _ = try await client.sendAuthorized(makeRequest("pin")) { _, _, _ -> (Data, URLResponse) in
                throw URLError(.cancelled)
            }
        } throws: { error in
            let networkError = error as? NetworkError
            return networkError?.classification == .secureConnectionFailed
                && networkError?.category == .insecureConnection
        }
    }

    @Test("Instrumentation sees two attempts, one retry, and one completion across a refresh")
    func instrumentationAcrossRefresh() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401), .success(Data("ok".utf8))], for: id)
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "new")
        )
        let recorder = NetworkInstrumentationRecorder()
        let client = makeClient(stub: stub, provider: provider, recorder: recorder)

        _ = try await client.sendAuthorized(makeRequest(id)) { request, session, delegate in
            try await session.data(for: request, delegate: delegate)
        }

        let started = await recorder.started
        #expect(started.map(\.attempt) == [1, 2])
        #expect(Set(started.map(\.requestID)).count == 1)
        #expect(await recorder.retried.count == 1)
        #expect(await recorder.completed.map(\.statusCode) == [200])
        #expect(await recorder.failed.isEmpty)
    }

    @Test("A response that is not HTTP throws invalidResponse")
    func nonHTTPResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = makeClient(stub: stub, provider: nil)
        let url = try #require(URL(string: "https://api.test.com/file"))

        await #expect {
            _ = try await client.sendAuthorized(URLRequest(url: url)) { _, _, _ in
                (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
            }
        } throws: { error in
            (error as? NetworkError)?.classification == .invalidResponse
        }
    }
}

extension URLRequest {
    fileprivate func withoutURL() -> URLRequest {
        var copy = self
        copy.url = nil
        return copy
    }
}
