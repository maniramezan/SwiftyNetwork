import Foundation
import Testing

@testable import SwiftyNetwork

// Serialized to bound how many stubbed URLSessions this suite holds from the finite shared pool.
@Suite("NetworkClient Retry Policy Tests", .serialized)
struct NetworkClientRetryTests {
    private let user = TestUser(id: "9", name: "Ada", email: "ada@example.com")

    private func makeClient(
        _ stub: TestHTTPStub,
        retryPolicy: NetworkRetryPolicy?,
        instrumentation: (any NetworkInstrumentation)? = nil
    ) -> NetworkClient {
        NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authRefreshDelay: 0,
                retryPolicy: retryPolicy,
                instrumentation: instrumentation
            )
        )
    }

    // MARK: - 429 surfaces Retry-After

    @Test("A 429 surfaces Retry-After seconds and the problem+json body without a retry policy")
    func surfacesRetryAfterSecondsAndBody() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-429-surface"
        let body = Data(#"{"code":"throttled"}"#.utf8)
        stub.setResponses([.status(429, data: body, headers: ["retry-after": "5"])], for: testId)
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        guard case .tooManyRequests(let response)? = error else {
            Issue.record("Expected tooManyRequests, got \(String(describing: error))")
            return
        }
        #expect(response.retryAfter == 5)
        #expect(response.body == body)
        #expect(stub.requests.count == 1)
    }

    @Test("A 429 surfaces an HTTP-date Retry-After as a non-negative delay")
    func surfacesHTTPDateRetryAfter() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-429-date"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date(timeIntervalSinceNow: 60))
        stub.setResponses([.status(429, headers: ["Retry-After": date])], for: testId)
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        let retryAfter = try #require(error?.retryAfter)
        #expect(retryAfter > 50 && retryAfter <= 60)
    }

    @Test("A 429 without Retry-After reports a nil delay")
    func missingRetryAfterIsNil() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-429-no-header"
        stub.setResponses([.status(429)], for: testId)
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        guard case .tooManyRequests(let response)? = error else {
            Issue.record("Expected tooManyRequests, got \(String(describing: error))")
            return
        }
        #expect(response.retryAfter == nil)
    }

    @Test("A 429 keeps its full response, including rate-limit headers")
    func tooManyRequestsCarriesResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-429-response"
        stub.setResponses(
            [.status(429, headers: ["Retry-After": "5", "X-RateLimit-Remaining": "0"])],
            for: testId
        )
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        let response = try #require(error?.response)
        #expect(response.statusCode == 429)
        #expect(response.header("x-ratelimit-remaining") == "0")
    }

    @Test("A 503 surfaces Retry-After and its full response")
    func serviceUnavailableCarriesRetryAfterAndResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-503-surface"
        let body = Data("maintenance".utf8)
        stub.setResponses(
            [.status(503, data: body, headers: ["Retry-After": "12", "X-Region": "eu"])],
            for: testId
        )
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        guard case .serverError(let response)? = error else {
            Issue.record("Expected serverError, got \(String(describing: error))")
            return
        }
        #expect(response.statusCode == 503)
        #expect(response.body == body)
        #expect(response.retryAfter == 12)
        #expect(response.header("x-region") == "eu")
    }

    @Test("Retry-After is ignored on statuses where it has no retry meaning")
    func retryAfterIgnoredOutsideRateLimitStatuses() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-500-ignored"
        stub.setResponses([.status(500, headers: ["Retry-After": "12"])], for: testId)
        let client = makeClient(stub, retryPolicy: nil)

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        #expect(error?.retryAfter == nil)
        #expect(error?.response?.header("Retry-After") == "12")
    }

    // MARK: - Opt-in policy

    @Test("Without a retry policy a transient failure is not retried")
    func noPolicyNoRetry() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-off"
        stub.setResponses([.status(503), .success(try JSONEncoder().encode(user))], for: testId)
        let client = makeClient(stub, retryPolicy: nil)

        await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }
        #expect(stub.requests.count == 1)
    }

    @Test("A GET is retried after 429, 5xx, timeout and lost connectivity, then succeeds")
    func retriesTransientFailuresOnGet() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-get-transients"
        stub.setResponses(
            [
                .status(429, headers: ["Retry-After": "0"]),
                .status(503),
                .failure(URLError(.timedOut)),
                .failure(URLError(.networkConnectionLost)),
                .success(try JSONEncoder().encode(user)),
            ],
            for: testId
        )
        let client = makeClient(stub, retryPolicy: .init(maxRetries: 4, baseDelay: 0, maxDelay: 0))

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(response == user)
        #expect(stub.requests.count == 5)
    }

    @Test("PUT and DELETE are retried")
    func retriesPutAndDelete() async throws {
        for method in [HTTPMethod.put, .delete] {
            let stub = try TestHTTPStub()
            defer { stub.invalidate() }
            let testId = "retry-\(method.rawValue)"
            stub.setResponses([.status(502), .success(try JSONEncoder().encode(user))], for: testId)
            let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0))

            let response = try await client.request(
                makeEndpointWithTestId(testId, method: method),
                responseType: TestUser.self
            )

            #expect(response == user)
            #expect(stub.requests.count == 2, "\(method)")
        }
    }

    @Test("A 429 on POST and PATCH is never retried")
    func neverRetriesNonIdempotent429() async throws {
        for method in [HTTPMethod.post, .patch] {
            let stub = try TestHTTPStub()
            defer { stub.invalidate() }
            let testId = "retry-no-\(method.rawValue)"
            stub.setResponses(
                [.status(429, headers: ["Retry-After": "0"]), .success(try JSONEncoder().encode(user))],
                for: testId
            )
            let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0))

            let error = await #expect(throws: NetworkError.self) {
                try await client.request(
                    makeEndpointWithTestId(testId, method: method),
                    responseType: TestUser.self
                )
            }

            guard case .tooManyRequests? = error else {
                Issue.record("Expected tooManyRequests for \(method), got \(String(describing: error))")
                continue
            }
            #expect(stub.requests.count == 1, "\(method)")
        }
    }

    @Test("Non-retryable failures are reported immediately")
    func doesNotRetryPermanentFailures() async throws {
        for status in [400, 403, 404] {
            let stub = try TestHTTPStub()
            defer { stub.invalidate() }
            let testId = "retry-permanent-\(status)"
            stub.setResponses([.status(status), .success(try JSONEncoder().encode(user))], for: testId)
            let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0))

            await #expect(throws: NetworkError.self) {
                try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            }
            #expect(stub.requests.count == 1, "status \(status)")
        }
    }

    @Test("Decoding failures are not retried")
    func doesNotRetryDecodingFailures() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-decoding"
        stub.setResponses([.success(Data("not json".utf8)), .success(try JSONEncoder().encode(user))], for: testId)
        let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0))

        await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }
        #expect(stub.requests.count == 1)
    }

    @Test("Retries stop at maxRetries and report the last error")
    func stopsAtMaxRetries() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-exhausted"
        stub.setResponses(
            [.status(503), .status(503), .status(500), .success(try JSONEncoder().encode(user))], for: testId)
        let client = makeClient(stub, retryPolicy: .init(maxRetries: 2, baseDelay: 0, maxDelay: 0))

        let error = await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        guard case .serverError(let response)? = error else {
            Issue.record("Expected serverError, got \(String(describing: error))")
            return
        }
        #expect(response.statusCode == 500)
        #expect(stub.requests.count == 3)
    }

    @Test("maxRetries of zero disables retrying")
    func zeroMaxRetriesDisables() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-zero"
        stub.setResponses([.status(503), .success(try JSONEncoder().encode(user))], for: testId)
        let client = makeClient(stub, retryPolicy: .init(maxRetries: 0))

        await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }
        #expect(stub.requests.count == 1)
    }

    // MARK: - Waiting

    @Test("Retry-After is honored, bounded by maxRetryAfter")
    func honorsRetryAfterBoundedByMax() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-after-wait"
        stub.setResponses(
            [.status(429, headers: ["Retry-After": "3600"]), .success(try JSONEncoder().encode(user))],
            for: testId
        )
        let client = makeClient(
            stub,
            retryPolicy: .init(baseDelay: 0, maxDelay: 0, jitterRange: 1...1, maxRetryAfter: 0.3)
        )

        let start = ContinuousClock.now
        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        let elapsed = start.duration(to: .now)

        #expect(response == user)
        #expect(elapsed >= .milliseconds(290))
        #expect(elapsed < .seconds(30))
    }

    @Test("A 503 Retry-After is honored, bounded by maxRetryAfter")
    func honorsServiceUnavailableRetryAfter() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-after-503-wait"
        stub.setResponses(
            [.status(503, headers: ["Retry-After": "3600"]), .success(try JSONEncoder().encode(user))],
            for: testId
        )
        let client = makeClient(
            stub,
            retryPolicy: .init(baseDelay: 0, maxDelay: 0, jitterRange: 1...1, maxRetryAfter: 0.3)
        )

        let start = ContinuousClock.now
        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        let elapsed = start.duration(to: .now)

        #expect(response == user)
        #expect(elapsed >= .milliseconds(290))
        #expect(elapsed < .seconds(30))
    }

    @Test("Cancelling the caller during the retry wait stops the request")
    func cancellationEndsRetryWait() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-cancel"
        stub.setResponses(
            [.status(429, headers: ["Retry-After": "30"]), .success(try JSONEncoder().encode(user))],
            for: testId
        )
        let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0, maxRetryAfter: 30))
        let endpoint = makeEndpointWithTestId(testId)

        let task = Task { try await client.request(endpoint, responseType: TestUser.self) }
        while stub.requests.isEmpty {
            await Task.yield()
        }
        // Give the client time to reach the Retry-After wait. If the cancel lands while the
        // first attempt is still on the wire, URLSession reports it as a cancelled URLError
        // instead; both outcomes must end the request promptly rather than waiting 30s.
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()

        let result = await task.result
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(stub.requests.count == 1)
        switch result {
        case .success:
            Issue.record("Expected the cancelled request to fail")
        case .failure(let error):
            let isCancellation =
                error is CancellationError
                || ((error as? NetworkError).flatMap { error -> URLError? in
                    guard case .underlying(let underlying) = error else { return nil }
                    return underlying as? URLError
                })?.code == .cancelled
            #expect(isCancellation, "Unexpected error: \(error)")
        }
    }

    // MARK: - Interaction with instrumentation and auth refresh

    @Test("Policy retries emit requestRetried and numbered attempts that share one requestID")
    func retriesAreInstrumented() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-instrumented"
        stub.setResponses([.status(503), .success(try JSONEncoder().encode(user))], for: testId)
        let instrumentation = FakeNetworkInstrumentation()
        let client = makeClient(
            stub,
            retryPolicy: .init(baseDelay: 0, maxDelay: 0),
            instrumentation: instrumentation
        )

        _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        let started = await instrumentation.started
        let retried = await instrumentation.retried
        let completed = await instrumentation.completed
        #expect(await instrumentation.failed.isEmpty)
        #expect(started.map(\.attempt) == [1, 2])
        #expect(retried.map(\.attempt) == [2])
        #expect(completed.map(\.attempt) == [2])
        #expect(Set(started.map(\.requestID) + retried.map(\.requestID)).count == 1)
    }

    @Test("An exhausted retry budget reports exactly one failure to instrumentation")
    func exhaustedRetriesReportOneFailure() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-instrumented-exhausted"
        stub.setResponses([.status(503), .status(503)], for: testId)
        let instrumentation = FakeNetworkInstrumentation()
        let client = makeClient(
            stub,
            retryPolicy: .init(maxRetries: 1, baseDelay: 0, maxDelay: 0),
            instrumentation: instrumentation
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }

        #expect(await instrumentation.started.map(\.attempt) == [1, 2])
        #expect(await instrumentation.failed.count == 1)
        #expect(await instrumentation.completed.isEmpty)
    }

    @Test("Auth refresh and policy retries use independent budgets on one request")
    func authRefreshAndRetryCompose() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-with-refresh"
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        stub.setResponses(
            [.status(401), .status(503), .success(try JSONEncoder().encode(user))],
            for: testId
        )
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                authRefreshDelay: 0,
                retryPolicy: .init(baseDelay: 0, maxDelay: 0)
            )
        )

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(response == user)
        #expect(await provider.refreshCallCount == 1)
        #expect(stub.requests.count == 3)
    }

    @Test("An encoded request body is replayed on retry")
    func encodedBodyIsReplayed() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "retry-body"
        stub.setResponses([.status(503), .success(try JSONEncoder().encode(user))], for: testId)
        let client = makeClient(stub, retryPolicy: .init(baseDelay: 0, maxDelay: 0))

        _ = try await client.request(
            makeEndpointWithTestId(testId, method: .put),
            body: user,
            responseType: TestUser.self
        )

        let bodies = stub.requests.compactMap { $0.httpBody ?? $0.httpBodyStream.flatMap(Self.readAll) }
        #expect(bodies.count == 2)
        #expect(Set(bodies).count == 1)
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
