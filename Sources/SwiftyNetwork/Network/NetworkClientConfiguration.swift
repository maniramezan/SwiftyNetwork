import Foundation

/// Configuration settings for ``NetworkClient``.
public struct NetworkClientConfiguration: Sendable {
    /// The URL session to use for network requests.
    public var session: URLSession

    /// The JSON decoder for parsing responses.
    public var decoder: JSONDecoder

    /// The JSON encoder for creating request bodies.
    public var encoder: JSONEncoder

    /// The authorization provider for handling authentication.
    public var authorizationProvider: AuthorizationProvider?

    /// Maximum number of authorization-refresh attempts after receiving a 401.
    ///
    /// This is **not** a general retry policy. ``NetworkClient`` does not
    /// retry transient network or 5xx errors automatically.
    public var maxAuthRefreshAttempts: Int

    /// The timeout interval for requests, in seconds.
    public var timeoutInterval: TimeInterval

    /// Delay applied before retrying a request after a successful auth refresh.
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
}
