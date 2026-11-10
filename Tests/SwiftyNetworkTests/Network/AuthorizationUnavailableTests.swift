import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("Authorization unavailable", .serialized)
struct AuthorizationUnavailableTests {
    private struct SignedOut: Error, Equatable {}

    /// A provider whose `currentAuthorization()` throws the scripted error.
    private struct ThrowingProvider: AuthorizationProvider {
        let error: any Error & Sendable

        func currentAuthorization() async throws -> AuthorizationType { throw error }
        func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}
    }

    @Test("A provider that throws fails the request with authorizationUnavailable and never sends it")
    func throwingProviderFailsWithoutSending() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "authorization-unavailable"
        stub.setResponses([.status(204)], for: testId)
        let recorder = NetworkInstrumentationRecorder()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: ThrowingProvider(error: SignedOut()),
                instrumentation: recorder
            )
        )

        await #expect {
            try await client.request(makeEndpointWithTestId(testId))
        } throws: { error in
            guard case .authorizationUnavailable(let underlying) = error as? NetworkError else { return false }
            return underlying is SignedOut
        }

        #expect(stub.requests.isEmpty)
        let failed = await recorder.failed
        #expect(failed.map(\.error.classification) == [.authorizationUnavailable])
    }

    @Test("A provider that throws CancellationError surfaces CancellationError")
    func cancelledProviderSurfacesCancellation() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: ThrowingProvider(error: CancellationError())
            )
        )

        await #expect(throws: CancellationError.self) {
            try await client.request(makeEndpointWithTestId("authorization-cancelled"))
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("Endpoint-level authorization does not consult the provider")
    func endpointAuthorizationSkipsProvider() async throws {
        struct KeyedEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            var path: String { "/keyed" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: "endpoint-auth")] }
            var authorization: AuthorizationType { .apiKey(key: "k") }
        }
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        stub.setResponses([.status(204)], for: "endpoint-auth")
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: ThrowingProvider(error: SignedOut())
            )
        )

        try await client.request(KeyedEndpoint())

        #expect(stub.getLastRequestHeaders(for: "endpoint-auth")?["X-API-Key"] == "k")
    }
}
