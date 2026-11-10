import Foundation
import Synchronization
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("Redirect Policy Tests")
struct RedirectPolicyTests {

    // MARK: - Fixtures

    private struct Endpoint: NetworkEndpoint {
        let baseURL: String
        var path: String { "/start" }
        var method: HTTPMethod { .get }
        var headers: [String: String]? {
            ["Accept": "application/json", "Cookie": "session=abc", "Proxy-Authorization": "Basic cHJveHk="]
        }
        var authorization: AuthorizationType = .none
    }

    private struct Payload: Codable, Sendable, Equatable {
        let ok: Bool
    }

    /// An app's session delegate that decides redirects itself and counts its calls.
    private final class AppRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        private let follows: Bool
        private let calls = Mutex(0)

        var callCount: Int { calls.withLock { $0 } }

        init(follows: Bool) {
            self.follows = follows
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            calls.withLock { $0 += 1 }
            return follows ? request : nil
        }
    }

    /// A pair of unique hosts plus a session, so tests never share routes.
    private struct Hosts {
        let origin = "origin-\(UUID().uuidString.lowercased()).test"
        let other = "other-\(UUID().uuidString.lowercased()).test"
        var session = RedirectingURLProtocol.makeSession()

        var start: URL {
            get throws { try RedirectPolicyTests.url("https://\(origin)/start") }
        }

        func client(
            policy: RedirectPolicy = .stripCredentialsAcrossOrigins,
            provider: (any AuthorizationProvider)? = nil
        ) -> NetworkClient {
            NetworkClient(
                configuration: NetworkClientConfiguration(
                    session: session,
                    authorizationProvider: provider,
                    authRefreshDelay: .zero,
                    redirectPolicy: policy
                )
            )
        }

        func tearDown() {
            session.invalidateAndCancel()
            RedirectingURLProtocol.unregister([origin, other])
        }
    }

    private static let okBody = Data(#"{"ok":true}"#.utf8)

    private static func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - End to end

    @Test("A cross-origin redirect is followed without the bearer token, cookies, or proxy credentials")
    func crossOriginRedirectStripsCredentials() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("https://\(hosts.other)/landing")), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        let payload = try await hosts.client().request(endpoint, responseType: Payload.self)

        #expect(payload == Payload(ok: true))
        let first = try #require(RedirectingURLProtocol.requests(forHost: hosts.origin).first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("A cross-origin redirect drops a custom API key header")
    func crossOriginRedirectStripsAPIKeyHeader() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("https://\(hosts.other)/landing")), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        let endpoint = Endpoint(
            baseURL: "https://\(hosts.origin)",
            authorization: .apiKey(key: "key-123", header: "X-Tenant-Key")
        )
        _ = try await hosts.client().request(endpoint, responseType: Payload.self)

        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "X-Tenant-Key") == nil)
    }

    @Test("Provider-supplied authorization is also stripped on a cross-origin redirect")
    func crossOriginRedirectStripsProviderAuthorization() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("https://\(hosts.other)/landing")), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        let provider = TestAuthorizationProvider(
            current: .custom(header: "X-Session", value: "s-1"), refreshResult: false)
        let client = hosts.client(provider: provider)
        _ = try await client.request(Endpoint(baseURL: "https://\(hosts.origin)"), responseType: Payload.self)

        let first = try #require(RedirectingURLProtocol.requests(forHost: hosts.origin).first)
        #expect(first.value(forHTTPHeaderField: "X-Session") == "s-1")
        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "X-Session") == nil)
    }

    @Test("A same-origin redirect keeps credentials")
    func sameOriginRedirectKeepsCredentials() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        let next = try Self.url("https://\(hosts.origin.uppercased()):443/next")
        RedirectingURLProtocol.register(.redirect(to: next), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: next)

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        _ = try await hosts.client().request(endpoint, responseType: Payload.self)

        let requests = RedirectingURLProtocol.requests(forHost: hosts.origin)
        try #require(requests.count == 2)
        #expect(requests[1].url?.path() == "/next")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "session=abc")
    }

    @Test("An HTTPS to HTTP downgrade is refused and surfaces the 3xx response")
    func downgradeIsRefused() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("http://\(hosts.other)/landing")), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        await #expect {
            try await hosts.client().request(endpoint, responseType: Payload.self)
        } throws: { error in
            guard case .unexpectedStatus(let response) = error as? NetworkError else { return false }
            return response.statusCode == 302 && response.header("Location") == "http://\(hosts.other)/landing"
        }
        #expect(RedirectingURLProtocol.requests(forHost: hosts.other).isEmpty)
    }

    @Test("The .never policy surfaces every redirect as unexpectedStatus")
    func neverPolicyRefusesRedirects() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("https://\(hosts.other)/landing"), statusCode: 307),
            for: try hosts.start
        )
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        await #expect {
            try await hosts.client(policy: .never).request(
                Endpoint(baseURL: "https://\(hosts.origin)"),
                responseType: Payload.self
            )
        } throws: { error in
            guard case .unexpectedStatus(let response) = error as? NetworkError else { return false }
            return response.statusCode == 307
        }
        #expect(RedirectingURLProtocol.requests(forHost: hosts.other).isEmpty)
    }

    @Test("The .followAll policy leaves redirects to the session, as 1.x did")
    func followAllForwardsHeadersUnchanged() async throws {
        let hosts = Hosts()
        defer { hosts.tearDown() }
        RedirectingURLProtocol.register(
            .redirect(to: try Self.url("https://\(hosts.other)/landing")), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: try Self.url("https://\(hosts.other)/landing"))

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        _ = try await hosts.client(policy: .followAll).request(endpoint, responseType: Payload.self)

        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(RedirectGuard(policy: .followAll, authorization: .bearer(token: "secret")) == nil)
    }

    // MARK: - The app's own redirect handling

    @Test("A session delegate that handles redirects decides, and its credentials pass through unchanged")
    func sessionDelegateFollowingIsRespected() async throws {
        let delegate = AppRedirectDelegate(follows: true)
        var hosts = Hosts()
        hosts.session = RedirectingURLProtocol.makeSession(delegate: delegate)
        defer { hosts.tearDown() }
        let landing = try Self.url("https://\(hosts.other)/landing")
        RedirectingURLProtocol.register(.redirect(to: landing), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: landing)

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        _ = try await hosts.client().request(endpoint, responseType: Payload.self)

        #expect(delegate.callCount == 1)
        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test(
        "A session delegate's refusal is respected under every policy",
        arguments: [RedirectPolicy.stripCredentialsAcrossOrigins, .never, .followAll]
    )
    func sessionDelegateRefusalIsRespected(policy: RedirectPolicy) async throws {
        let delegate = AppRedirectDelegate(follows: false)
        var hosts = Hosts()
        hosts.session = RedirectingURLProtocol.makeSession(delegate: delegate)
        defer { hosts.tearDown() }
        // A same-origin redirect, which every built-in policy except `.never` would follow.
        let next = try Self.url("https://\(hosts.origin)/next")
        RedirectingURLProtocol.register(.redirect(to: next), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: next)

        await #expect {
            try await hosts.client(policy: policy).request(
                Endpoint(baseURL: "https://\(hosts.origin)"),
                responseType: Payload.self
            )
        } throws: { error in
            guard case .unexpectedStatus(let response) = error as? NetworkError else { return false }
            return response.statusCode == 302
        }
        #expect(delegate.callCount == 1)
        #expect(RedirectingURLProtocol.requests(forHost: hosts.origin).count == 1)
    }

    @Test("A pinned session, whose delegate does not handle redirects, still gets the redirect policy")
    func pinnedSessionStillStripsCredentials() async throws {
        var hosts = Hosts()
        hosts.session = SSLPinningConfiguration(pinnedHosts: [:])
            .makeSession(configuration: RedirectingURLProtocol.makeConfiguration())
        defer { hosts.tearDown() }
        let landing = try Self.url("https://\(hosts.other)/landing")
        RedirectingURLProtocol.register(.redirect(to: landing), for: try hosts.start)
        RedirectingURLProtocol.register(.ok(Self.okBody), for: landing)

        let endpoint = Endpoint(baseURL: "https://\(hosts.origin)", authorization: .bearer(token: "secret"))
        _ = try await hosts.client().request(endpoint, responseType: Payload.self)

        let redirected = try #require(RedirectingURLProtocol.requests(forHost: hosts.other).first)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Origin

    @Test(
        "Origins compare scheme, host, and effective port case-insensitively",
        arguments: [
            ("https://api.example.com/a", "https://API.example.com/b", true),
            ("https://api.example.com/a", "https://api.example.com:443/b", true),
            ("http://api.example.com/a", "http://api.example.com:80/b", true),
            ("https://api.example.com/a", "https://api.example.com:8443/b", false),
            ("https://api.example.com/a", "https://cdn.example.com/b", false),
            ("http://api.example.com/a", "https://api.example.com/b", false),
        ]
    )
    func originEquality(lhs: String, rhs: String, same: Bool) throws {
        let isSame = Origin(try Self.url(lhs)) == Origin(try Self.url(rhs))
        #expect(isSame == same)
    }

    @Test("An HTTP to HTTPS upgrade to the same host is followed without credentials")
    func upgradeChangesOrigin() throws {
        let redirectGuard = try #require(
            RedirectGuard(policy: .stripCredentialsAcrossOrigins, authorization: .basic(username: "u", password: "p"))
        )
        var proposed = URLRequest(url: try Self.url("https://api.example.com/next"))
        proposed.setValue("Basic dTpw", forHTTPHeaderField: "Authorization")
        let followed = redirectGuard.redirect(proposed, from: try Self.url("http://api.example.com/start"))

        #expect(followed?.url?.scheme == "https")
        #expect(followed?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("The default configuration strips credentials across origins")
    func defaultConfigurationPolicy() {
        #expect(NetworkClientConfiguration().redirectPolicy == .stripCredentialsAcrossOrigins)
    }

    @Test("RedirectPolicy conforms to Equatable")
    func redirectPolicyEquatable() {
        #expect(RedirectPolicy.stripCredentialsAcrossOrigins == .stripCredentialsAcrossOrigins)
        #expect(RedirectPolicy.followAll == .followAll)
        #expect(RedirectPolicy.never == .never)
        #expect(RedirectPolicy.stripCredentialsAcrossOrigins != .followAll)
        #expect(RedirectPolicy.stripCredentialsAcrossOrigins != .never)
        #expect(RedirectPolicy.followAll != .never)
    }
}
