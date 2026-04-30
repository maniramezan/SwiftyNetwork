import Foundation

/// Configuration settings for ``NetworkClient``.
///
/// Use this value to inject test sessions, customize JSON coding strategies,
/// configure authorization refresh, adjust timeouts, and control package logging.
/// A configuration is copied into each request when it starts, so updating a
/// client affects subsequent requests but not work already in flight.
///
/// Example:
/// ```swift
/// let decoder = JSONDecoder()
/// decoder.dateDecodingStrategy = .iso8601
///
/// let provider = OAuthAuthorizationProvider(initialAccessToken: "token") {
///     await refreshAccessToken()
/// }
///
/// let configuration = NetworkClientConfiguration(
///     decoder: decoder,
///     authorizationProvider: provider,
///     timeoutInterval: 15,
///     logLevel: .info
/// )
/// let client = NetworkClient(configuration: configuration)
/// ```
public struct NetworkClientConfiguration: Sendable {
    /// The URL session to use for network requests.
    ///
    /// Inject a custom session for tests, custom cache policies, proxy settings,
    /// or `URLProtocol` interception. Defaults to `URLSession.shared`.
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
    public var authorizationProvider: AuthorizationProvider?

    /// Maximum number of authorization-refresh attempts after receiving a 401.
    ///
    /// This is **not** a general retry policy. ``NetworkClient`` does not
    /// retry transient network or 5xx errors automatically.
    public var maxAuthRefreshAttempts: Int

    /// The timeout interval for requests, in seconds.
    ///
    /// This value is assigned to each `URLRequest.timeoutInterval` built by the client.
    public var timeoutInterval: TimeInterval

    /// Delay applied before retrying a request after a successful auth refresh.
    ///
    /// Set this to `0` in tests or when the API can be retried immediately.
    public var retryDelay: TimeInterval

    /// Verbosity for SwiftyNetwork's internal logger.
    ///
    /// Setting this updates the package-wide log level when a client is created
    /// or its configuration is replaced.
    public var logLevel: LogLevel

    /// Creates a new network client configuration.
    ///
    /// - Parameters:
    ///   - session: The URL session to use. Defaults to `.shared`.
    ///   - decoder: The JSON decoder to use.
    ///   - encoder: The JSON encoder to use.
    ///   - authorizationProvider: The authorization provider. Defaults to `nil`.
    ///   - maxAuthRefreshAttempts: Maximum auth-refresh attempts after a 401. Defaults to 1.
    ///   - timeoutInterval: Request timeout interval. Defaults to 30 seconds.
    ///   - retryDelay: Delay before retrying after auth refresh. Defaults to 1 second.
    ///   - logLevel: Verbosity for the internal logger. Defaults to ``LogLevel/warning``.
    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        authorizationProvider: AuthorizationProvider? = nil,
        maxAuthRefreshAttempts: Int = 1,
        timeoutInterval: TimeInterval = 30,
        retryDelay: TimeInterval = 1.0,
        logLevel: LogLevel = .warning
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
        self.authorizationProvider = authorizationProvider
        self.maxAuthRefreshAttempts = max(0, maxAuthRefreshAttempts)
        self.timeoutInterval = timeoutInterval
        self.retryDelay = retryDelay
        self.logLevel = logLevel
    }

    /// Creates a new network client configuration backed by an SSL-pinned `URLSession`.
    ///
    /// Use this initializer when you need certificate or public-key pinning. Pinning is
    /// applied only to hosts listed in `sslPinning`; all other hosts use normal
    /// `URLSession` trust handling.
    ///
    /// - Parameters:
    ///   - sslPinning: Host pinning policies to enforce.
    ///   - sessionConfiguration: The base URL session configuration. Defaults to `.default`.
    ///   - delegateQueue: Queue used for URL session delegate callbacks. Defaults to the system queue.
    ///   - decoder: The JSON decoder to use.
    ///   - encoder: The JSON encoder to use.
    ///   - authorizationProvider: The authorization provider. Defaults to `nil`.
    ///   - maxAuthRefreshAttempts: Maximum auth-refresh attempts after a 401. Defaults to 1.
    ///   - timeoutInterval: Request timeout interval. Defaults to 30 seconds.
    ///   - retryDelay: Delay before retrying after auth refresh. Defaults to 1 second.
    ///   - logLevel: Verbosity for the internal logger. Defaults to ``LogLevel/warning``.
    public init(
        sslPinning: SSLPinningConfiguration,
        sessionConfiguration: URLSessionConfiguration = .default,
        delegateQueue: OperationQueue? = nil,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        authorizationProvider: AuthorizationProvider? = nil,
        maxAuthRefreshAttempts: Int = 1,
        timeoutInterval: TimeInterval = 30,
        retryDelay: TimeInterval = 1.0,
        logLevel: LogLevel = .warning
    ) {
        let delegate = SSLPinningURLSessionDelegate(configuration: sslPinning)
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        self.init(
            session: session,
            decoder: decoder,
            encoder: encoder,
            authorizationProvider: authorizationProvider,
            maxAuthRefreshAttempts: maxAuthRefreshAttempts,
            timeoutInterval: timeoutInterval,
            retryDelay: retryDelay,
            logLevel: logLevel
        )
    }
}
