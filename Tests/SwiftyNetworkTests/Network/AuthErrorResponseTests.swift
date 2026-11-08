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

@Suite("HTTPErrorResponse")
struct HTTPErrorResponseTests {
    @Test("Header lookup ignores case and exposes the WWW-Authenticate challenge")
    func headerLookupIsCaseInsensitive() {
        let response = HTTPErrorResponse(
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
        let response = HTTPErrorResponse(statusCode: 403, body: errorBody("registration_required"))
        #expect(try response.decodeBody(APIErrorBody.self) == APIErrorBody(code: "registration_required"))

        let empty = HTTPErrorResponse(statusCode: 403)
        #expect(throws: DecodingError.self) {
            try empty.decodeBody(APIErrorBody.self)
        }
    }

    @Test("Only 401 and 403 errors carry a response")
    func responseAccessorIsLimitedToAuthErrors() {
        let response = HTTPErrorResponse(statusCode: 401)
        #expect(NetworkError.unauthorized(response: response).response == response)
        #expect(NetworkError.forbidden(response: response).response == response)
        #expect(NetworkError.unauthorized().response == nil)
        #expect(NetworkError.forbidden().response == nil)
        #expect(NetworkError.notFound.response == nil)
        #expect(NetworkError.serverError(statusCode: 500, data: nil).response == nil)
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
            #expect(response?.statusCode == 401)
            #expect(response?.wwwAuthenticate == challenge)
            #expect(try response?.decodeBody(APIErrorBody.self) == APIErrorBody(code: "not_authenticated"))
        }
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
                retryDelay: 0
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
            #expect(try response?.decodeBody(APIErrorBody.self) == APIErrorBody(code: "not_authenticated"))
        }
        #expect(await provider.refreshCallCount == 1)
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
                retryDelay: 0
            )
        )
        let testId = "auth-response-403"
        stub.setResponses([.status(403, data: errorBody("registration_required"))], for: testId)

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 403 to throw")
        } catch NetworkError.forbidden(let response) {
            #expect(response?.statusCode == 403)
            #expect(response?.wwwAuthenticate == nil)
            #expect(try response?.decodeBody(APIErrorBody.self) == APIErrorBody(code: "registration_required"))
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
                retryDelay: 0
            )
        )
        let testId = "auth-response-decline"
        stub.setResponses([.status(401, data: errorBody("unrelated"))], for: testId)

        do {
            _ = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)
            Issue.record("Expected a 401 to throw")
        } catch NetworkError.unauthorized(let response) {
            #expect(try response?.decodeBody(APIErrorBody.self) == APIErrorBody(code: "unrelated"))
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
                retryDelay: 0
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
    @Test("401 and 403 from the byte cache carry the response")
    func cacheErrorsCarryResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        for (status, code) in [(401, "authentication_failed"), (403, "registration_required")] {
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
}
