import Foundation
import SwiftyNetworkTesting
import TestCommons
import Testing

@testable import SwiftyNetwork

private struct APIErrorBody: Decodable, Equatable {
    let code: String
}

private let challenge = #"Bearer realm="novalingo""#

private func errorBody(_ code: String) -> Data {
    Data(#"{"code":"\#(code)"}"#.utf8)
}

@Suite("HTTPResponse")
struct HTTPResponseTests {
    @Test("Header lookup ignores case and exposes the WWW-Authenticate challenge")
    func headerLookupIsCaseInsensitive() {
        let response = HTTPResponse(
            statusCode: 401,
            headers: ["Www-Authenticate": challenge, "Content-Type": "application/json"]
        )

        #expect(response.header("www-authenticate") == challenge)
        #expect(response.header("CONTENT-TYPE") == "application/json")
        #expect(response.header("Retry-After") == nil)
        #expect(response.wwwAuthenticate == challenge)
    }

    @Test("Decodes the body and surfaces decoding failures for empty bodies")
    func decodesBody() throws {
        let response = HTTPResponse(statusCode: 403, body: errorBody("registration_required"))
        #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "registration_required"))

        let empty = HTTPResponse(statusCode: 403)
        #expect(throws: DecodingError.self) {
            try empty.decodeBody(APIErrorBody.self)
        }
    }

    @Test("Snapshots status, headers, and body from an HTTPURLResponse")
    func snapshotsHTTPURLResponse() throws {
        let url = try #require(URL(string: "https://api.test.com/x"))
        let httpResponse = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Request-Id": "abc", "Content-Type": "application/json"]
            )
        )
        let body = errorBody("registration_required")

        let response = HTTPResponse(httpResponse, body: body)

        #expect(response.statusCode == 403)
        #expect(response.header("x-request-id") == "abc")
        #expect(response.body == body)
    }

    @Test("Descriptions redact header values and body bytes, including inside a NetworkError")
    func descriptionsAreRedacted() {
        let response = HTTPResponse(
            statusCode: 401,
            headers: ["Set-Cookie": "session=SECRET-COOKIE", "X-Request-Id": "abc"],
            body: Data("SECRET-BODY".utf8)
        )
        let error = NetworkError.unauthorized(response)

        for text in [
            response.description,
            response.debugDescription,
            String(describing: response),
            String(reflecting: response),
            "\(response)",
            String(describing: error),
            String(reflecting: error),
        ] {
            #expect(!text.contains("SECRET"))
            #expect(text.contains("401"))
        }
        #expect(
            response.description
                == "HTTPResponse(statusCode: 401, headers: [Set-Cookie, X-Request-Id], body: 11 bytes)"
        )
    }

    @Test("Every HTTP error exposes its response; transport errors return nil")
    func responseAccessorCoversHTTPErrors() {
        let response = HTTPResponse(statusCode: 401)
        #expect(NetworkError.unauthorized(response).response == response)
        #expect(NetworkError.forbidden(response).response == response)
        #expect(NetworkError.tooManyRequests(response).response == response)
        #expect(NetworkError.clientError(response).response == response)
        #expect(NetworkError.serverError(response).response == response)
        #expect(NetworkError.unexpectedStatus(response).response == response)
        #expect(NetworkError.notFound(response).response == response)
        #expect(NetworkError.timeout(response).response == response)

        #expect(NetworkError.timeout(nil).response == nil)
        #expect(NetworkError.noInternetConnection.response == nil)
        #expect(NetworkError.invalidResponse.response == nil)
    }
}

@Suite("NetworkClient auth error responses")
struct NetworkClientAuthErrorResponseTests {
    @Test("A 401 without a provider keeps status, headers, and body")
    func unauthorizedWithoutProviderCarriesResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))
        let testId = "auth-response-401-no-provider"
        stub.setResponses(
            [.status(401, data: errorBody("not_authenticated"), headers: ["WWW-Authenticate": challenge])],
            for: testId
        )

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 401 to throw")
        } catch NetworkError.unauthorized(let response) {
            #expect(response.statusCode == 401)
            #expect(response.wwwAuthenticate == challenge)
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "not_authenticated"))
        }
    }

    @Test("A 404 and a 408 keep their status, headers, and body")
    func notFoundAndTimeoutCarryResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))

        for status in [404, 408] {
            let testId = "auth-response-\(status)"
            stub.setResponses(
                [.status(status, data: errorBody("missing_\(status)"), headers: ["X-Test": "1"])],
                for: testId
            )

            let error = await #expect(throws: NetworkError.self) {
                try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            }

            let response = try #require(error?.response)
            #expect(response.statusCode == status)
            #expect(response.header("x-test") == "1")
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "missing_\(status)"))
            switch status {
            case 404:
                guard case .notFound? = error else {
                    Issue.record("Expected notFound, got \(String(describing: error))")
                    return
                }
            default:
                guard case .timeout? = error else {
                    Issue.record("Expected timeout, got \(String(describing: error))")
                    return
                }
            }
        }
    }

    @Test("A transport timeout has no response")
    func transportTimeoutHasNoResponse() {
        #expect(NetworkError.mapURLError(URLError(.timedOut)).response == nil)
    }

    @Test("After a refresh and retry, the error carries the final 401")
    func unauthorizedAfterRetryCarriesLastResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "new")
        )
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 1,
                authRefreshDelay: .zero
            )
        )
        let testId = "auth-response-401-after-retry"
        stub.setResponses(
            [
                .status(401, data: errorBody("authentication_failed"), headers: ["WWW-Authenticate": challenge]),
                .status(401, data: errorBody("not_authenticated"), headers: ["WWW-Authenticate": challenge]),
            ],
            for: testId
        )

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 401 to throw")
        } catch NetworkError.unauthorized(let response) {
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "not_authenticated"))
        }
        #expect(await provider.refreshCallCount == 1)
    }

    @Test("A 401 for endpoint-supplied authorization carries the response and skips the provider")
    func endpointAuthorizationUnauthorizedSkipsProvider() async throws {
        struct BearerEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/me" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
            var authorization: AuthorizationType { .bearer(token: "endpoint-token") }
        }
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(current: .bearer(token: "provider"), refreshResult: true)
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 1,
                authRefreshDelay: .zero
            )
        )
        let testId = "auth-response-endpoint-auth"
        stub.setResponses([.status(401, data: errorBody("authentication_failed"))], for: testId)

        do {
            _ = try await client.request(BearerEndpoint(testId: testId), responseType: TestUser.self)
            Issue.record("Expected a 401 to throw")
        } catch NetworkError.unauthorized(let response) {
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "authentication_failed"))
        }
        #expect(await provider.inspectedResponses.isEmpty)
        #expect(await provider.refreshCallCount == 0)
    }

    @Test("The provider is not consulted once the refresh budget is spent")
    func providerNotConsultedWhenBudgetIsZero() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(current: .bearer(token: "token"), refreshResult: true)
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 0,
                authRefreshDelay: .zero
            )
        )
        let testId = "auth-response-zero-budget"
        stub.setResponses([.status(401, data: errorBody("authentication_failed"))], for: testId)

        await #expect(throws: NetworkError.self) {
            try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
        }
        #expect(await provider.inspectedResponses.isEmpty)
        #expect(await provider.refreshCallCount == 0)
    }

    @Test("A 403 keeps its body and never triggers a refresh")
    func forbiddenCarriesResponseWithoutRefresh() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "guest"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "other")
        )
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 1,
                authRefreshDelay: .zero
            )
        )
        let testId = "auth-response-403"
        stub.setResponses([.status(403, data: errorBody("registration_required"))], for: testId)

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 403 to throw")
        } catch NetworkError.forbidden(let response) {
            #expect(response.statusCode == 403)
            #expect(response.wwwAuthenticate == nil)
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "registration_required"))
        }
        #expect(await provider.refreshCallCount == 0)
        #expect(stub.requests.count == 1)
    }

    @Test("A provider can decline to refresh after inspecting the 401 body")
    func providerCanDeclineRefresh() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "token"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh"),
            shouldRefresh: { response in
                (try? response.decodeBody(APIErrorBody.self))?.code != "unrelated"
            }
        )
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 1,
                authRefreshDelay: .zero
            )
        )
        let testId = "auth-response-decline"
        stub.setResponses([.status(401, data: errorBody("unrelated"))], for: testId)

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 401 to throw")
        } catch NetworkError.unauthorized(let response) {
            #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "unrelated"))
        }
        #expect(await provider.refreshCallCount == 0)
        #expect(await provider.inspectedResponses.count == 1)
        #expect(stub.requests.count == 1)
    }

    @Test("A provider that accepts the 401 still gets refresh-once-and-retry")
    func providerAcceptingRefreshRetriesOnce() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "old"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "new"),
            shouldRefresh: { _ in true }
        )
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                maxAuthRefreshAttempts: 1,
                authRefreshDelay: .zero
            )
        )
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let testId = "auth-response-accept"
        stub.setResponses(
            [.status(401, data: errorBody("authentication_failed")), .success(try JSONEncoder().encode(user))],
            for: testId
        )

        let result = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(result == user)
        #expect(await provider.refreshCallCount == 1)
        #expect(stub.requests.count == 2)
    }
}

@Suite("RemoteDataCache auth error responses")
struct RemoteDataCacheAuthErrorResponseTests {
    @Test("401, 403, 404 and 408 from the byte cache carry the response")
    func cacheErrorsCarryResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        for (status, code) in [
            (401, "authentication_failed"), (403, "registration_required"), (404, "missing"), (408, "slow"),
        ] {
            let testId = "cache-auth-\(status)"
            stub.setResponses([.status(status, data: errorBody(code), headers: ["X-Test": "1"])], for: testId)
            let url = try #require(URL(string: "https://api.test.com/img?test-id=\(testId)"))

            do {
                _ = try await cache.data(for: url)
                Issue.record("Expected status \(status) to throw")
            } catch let error as NetworkError {
                let response = try #require(error.response)
                #expect(response.statusCode == status)
                #expect(response.header("x-test") == "1")
                #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: code))
            }
        }
    }

    @Test("429 and 503 from the byte cache carry the response and Retry-After")
    func cacheRateLimitErrorsCarryResponseAndRetryAfter() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        for status in [429, 503] {
            let testId = "cache-rate-limit-\(status)"
            stub.setResponses([.status(status, headers: ["Retry-After": "9", "X-Test": "1"])], for: testId)
            let url = try #require(URL(string: "https://api.test.com/img?test-id=\(testId)"))

            do {
                _ = try await cache.data(for: url)
                Issue.record("Expected status \(status) to throw")
            } catch let error as NetworkError {
                #expect(error.retryAfter == .seconds(9))
                #expect(error.response?.statusCode == status)
                #expect(error.response?.header("x-test") == "1")
            }
        }
    }
}
