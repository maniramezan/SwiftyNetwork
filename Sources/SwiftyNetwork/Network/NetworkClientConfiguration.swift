import Foundation
internal import SwiftCommons

/// Configuration settings for ``NetworkClient``.
///
/// Use this value to inject test sessions, customize JSON coding strategies,
/// configure authorization refresh, retries, timeouts, and instrumentation.
/// A client keeps the configuration it was created with; create a new client
/// to change it. Set the package-wide log level with ``LogLevel/current``.
///
/// Example:
/// ```swift
/// let decoder = JSONDecoder()
/// decoder.dateDecodingStrategy = .iso8601
///
/// let provider = OAuthAuthorizationProvider(initialAccessToken: "token") {
///     try await refreshAccessToken()
/// }
///
/// let configuration = NetworkClientConfiguration(
///     decoder: decoder,
///     authorizationProvider: provider,
///     timeout: .seconds(15)
/// )
/// let client = NetworkClient(configuration: configuration)
/// ```
///
/// To pin TLS certificates, pass a session from ``SSLPinningConfiguration/makeSession(configuration:delegateQueue:)``:
/// ```swift
/// let configuration = NetworkClientConfiguration(session: pinning.makeSession())
/// ```
public struct NetworkClientConfiguration: Sendable {
    /// The URL session to use for network requests.
    ///
    /// Inject a custom session for tests, custom cache policies, proxy settings,
    /// `URLProtocol` interception, or TLS pinning
    /// (``SSLPinningConfiguration/makeSession(configuration:delegateQueue:)``).
    /// Defaults to `URLSession.shared`.
    public var session: URLSession

    /// The JSON decoder for parsing responses.
    ///
    /// Configure this when your API uses custom dates, key decoding strategies, or
    /// other `Codable` conventions.
    public var decoder: JSONDecoder

    /// The JSON encoder for creating request bodies.
    ///
    /// Used by ``NetworkClient/request(_:body:responseType:)`` when encoding an
    /// `Encodable` request body.
    public var encoder: JSONEncoder

    /// The authorization provider for handling authentication.
    ///
    /// When an endpoint's ``NetworkEndpoint/authorization`` is ``AuthorizationType/none``,
    /// the client asks this provider for authorization and can call it again to
    /// refresh credentials after a `401` response.
    public var authorizationProvider: (any AuthorizationProvider)?

    /// Maximum number of authorization-refresh attempts after receiving a 401.
    ///
    /// This is **not** a general retry policy; see ``retryPolicy`` for retrying
    /// transient failures.
    public var maxAuthRefreshAttempts: Int

    /// Delay applied before replaying a request after a successful auth refresh.
    ///
    /// This applies only to the `401` refresh path. It is unrelated to ``retryPolicy``,
    /// which controls backoff for transient failures.
    ///
    /// Set this to `.zero` in tests or when the API can be retried immediately.
    public var authRefreshDelay: Duration

    /// Opt-in retry policy for transient failures of idempotent requests.
    ///
    /// `nil` by default, in which case ``NetworkClient`` never retries a
    /// transient network, `429` or 5xx failure. When set, `GET`, `HEAD`, `PUT`
    /// and `DELETE` requests are retried on `429` and 5xx (honoring `Retry-After` on `429` and `503`),
    /// timeouts and lost connectivity, with jittered exponential backoff.
    /// `POST` and `PATCH` are never retried. See ``NetworkRetryPolicy``.
    public var retryPolicy: NetworkRetryPolicy?

    /// How the client treats HTTP redirects.
    ///
    /// Defaults to ``RedirectPolicy/stripCredentialsAcrossOrigins``, which removes
    /// credentials from a redirect to another origin and refuses an `https` to `http`
    /// downgrade. If ``session``'s delegate handles redirects itself, it decides every
    /// redirect and this policy is not applied.
    public var redirectPolicy: RedirectPolicy

    /// The timeout for each request.
    ///
    /// This value is assigned to each `URLRequest.timeoutInterval` built by the client.
    public var timeout: Duration

    /// Observer for request timing, retries, and outcomes.
    ///
    /// Inject an app-supplied ``NetworkInstrumentation`` conformance to feed
    /// events into your own observability stack (e.g. an OpenTelemetry
    /// adapter) without SwiftyNetwork depending on that SDK. `nil` by
    /// default -- instrumentation is entirely opt-in.
    public var instrumentation: (any NetworkInstrumentation)?

    /// Creates a new network client configuration.
    ///
    /// - Parameters:
    ///   - session: The URL session to use. Defaults to `.shared`.
    ///   - decoder: The JSON decoder to use.
    ///   - encoder: The JSON encoder to use.
    ///   - authorizationProvider: The authorization provider. Defaults to `nil`.
    ///   - maxAuthRefreshAttempts: Maximum auth-refresh attempts after a 401. Defaults to 1.
    ///   - authRefreshDelay: Delay before retrying after auth refresh. Defaults to 1 second.
    ///   - retryPolicy: Opt-in retry policy for idempotent requests. Defaults to `nil` (no retries).
    ///   - redirectPolicy: How redirects are followed. Defaults to
    ///     ``RedirectPolicy/stripCredentialsAcrossOrigins``.
    ///   - timeout: The timeout for each request. Defaults to 30 seconds.
    ///   - instrumentation: Observer for request lifecycle events. Defaults to `nil`.
    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        authorizationProvider: (any AuthorizationProvider)? = nil,
        maxAuthRefreshAttempts: Int = 1,
        authRefreshDelay: Duration = .seconds(1),
        retryPolicy: NetworkRetryPolicy? = nil,
        redirectPolicy: RedirectPolicy = .stripCredentialsAcrossOrigins,
        timeout: Duration = .seconds(30),
        instrumentation: (any NetworkInstrumentation)? = nil
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
        self.authorizationProvider = authorizationProvider
        self.maxAuthRefreshAttempts = max(0, maxAuthRefreshAttempts)
        self.authRefreshDelay = authRefreshDelay
        self.retryPolicy = retryPolicy
        self.redirectPolicy = redirectPolicy
        self.timeout = timeout
        self.instrumentation = instrumentation
    }
}
