import Foundation

/// A thread-safe network client that handles HTTP requests with auth refresh on 401.
///
/// ``NetworkClient`` does not perform general retries on transient errors. It
/// will, however, refresh authorization once on 401 (up to
/// ``NetworkClientConfiguration/maxAuthRefreshAttempts``) and retry the
/// original request with the new credentials.
///
/// Example:
/// ```swift
/// struct User: Decodable, Sendable {
///     let id: String
///     let name: String
/// }
///
/// let client = NetworkClient()
/// let user = try await client.request(UserEndpoint(id: "123"), responseType: User.self)
/// ```
public actor NetworkClient: NetworkDataSource {

    private var configuration: NetworkClientConfiguration
    private var requestAttemptCount = 0

    /// Shared client with default configuration.
    ///
    /// Suitable for simple apps. For testability or multiple distinct
    /// configurations, create dedicated ``NetworkClient`` instances.
    ///
    /// Example:
    /// ```swift
    /// let user = try await NetworkClient.shared.request(endpoint, responseType: User.self)
    /// ```
    public static let shared = NetworkClient()

    /// Creates a new network client.
    ///
    /// Example:
    /// ```swift
    /// let configuration = NetworkClientConfiguration(timeoutInterval: 10, logLevel: .debug)
    /// let client = NetworkClient(configuration: configuration)
    /// ```
    ///
    /// - Parameter configuration: The configuration to use.
    public init(configuration: NetworkClientConfiguration = NetworkClientConfiguration()) {
        self.configuration = configuration
        Logger.setLevel(configuration.logLevel)
    }

    /// Replaces the active configuration atomically.
    ///
    /// Existing in-flight requests continue with the configuration captured when
    /// they started. New requests use `newConfiguration`.
    ///
    /// Example:
    /// ```swift
    /// await client.updateConfiguration(NetworkClientConfiguration(logLevel: .info))
    /// ```
    ///
    /// - Parameter newConfiguration: The new configuration to apply.
    public func updateConfiguration(_ newConfiguration: NetworkClientConfiguration) {
        self.configuration = newConfiguration
        Logger.setLevel(newConfiguration.logLevel)
    }

    /// Returns the cumulative number of request **attempts** made by this client,
    /// including retries triggered by auth refresh.
    ///
    /// Example:
    /// ```swift
    /// let attempts = await client.attemptCount()
    /// ```
    public func attemptCount() async -> Int {
        requestAttemptCount
    }

    // MARK: - Public Request API

    /// Performs a network request and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - responseType: The expected `Decodable` response type.
    /// - Returns: A decoded value of `responseType`.
    /// - Throws: ``NetworkError`` if the request, response, or decoding fails.
    ///
    /// Example:
    /// ```swift
    /// let profile = try await client.request(ProfileEndpoint(), responseType: Profile.self)
    /// ```
    public func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let configuration = self.configuration
        return try await performRequest(
            endpoint,
            responseType: responseType,
            refreshAttempt: 0,
            configuration: configuration
        )
    }

    /// Performs a network request that is expected to return no response body.
    ///
    /// - Parameter endpoint: The endpoint describing the request.
    /// - Throws: ``NetworkError`` if the request or response fails.
    ///
    /// Example:
    /// ```swift
    /// try await client.request(DeleteProfileEndpoint())
    /// ```
    public func request(_ endpoint: any NetworkEndpoint) async throws {
        _ = try await request(endpoint, responseType: EmptyResponse.self)
    }

    /// Performs a network request with an `Encodable` body, encoding it via the
    /// configured `JSONEncoder`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected `Decodable` response type.
    /// - Returns: A decoded value of `responseType`.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if encoding fails;
    ///   other ``NetworkError`` cases on transport or decoding failures.
    ///
    /// Example:
    /// ```swift
    /// let draft = CreatePostRequest(title: "Hello", body: "...")
    /// let post = try await client.request(CreatePostEndpoint(), body: draft, responseType: Post.self)
    /// ```
    public func request<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> T {
        let configuration = self.configuration
        let encodedBody: Data
        do {
            encodedBody = try configuration.encoder.encode(body)
        } catch {
            Logger.error("Failed to encode request body", error: error)
            throw NetworkError.encodingFailed(underlying: AnySendableError(error))
        }

        let wrapped = EncodedBodyEndpoint(wrapped: endpoint, encodedBody: encodedBody)
        return try await performRequest(
            wrapped,
            responseType: responseType,
            refreshAttempt: 0,
            configuration: configuration
        )
    }

    // MARK: - Private Request Pipeline

    private func performRequest<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        configuration: NetworkClientConfiguration
    ) async throws -> T {
        requestAttemptCount += 1
        Logger.debug("Starting request (attempt \(refreshAttempt + 1))")

        let url = try EndpointURLBuilder.url(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            queryItems: endpoint.queryItems
        )
        Logger.debugURL("Resolved URL", url: url)

        var request = buildURLRequest(from: endpoint, url: url, configuration: configuration)
        let providerAuthApplied = await applyAuthorization(
            to: &request,
            from: endpoint,
            configuration: configuration
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await configuration.session.data(for: request)
        } catch let error as URLError {
            Logger.error("URL error during request", error: error)
            throw mapURLError(error)
        } catch {
            Logger.error("Unexpected error during request", error: error)
            throw NetworkError.underlying(AnySendableError(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            return try await handleUnauthorized(
                endpoint: endpoint,
                responseType: responseType,
                refreshAttempt: refreshAttempt,
                providerAuthApplied: providerAuthApplied,
                configuration: configuration
            )
        }

        try validateStatusCode(httpResponse.statusCode, data: data)
        return try decodeResponse(data: data, responseType: responseType, configuration: configuration)
    }

    private func buildURLRequest(
        from endpoint: any NetworkEndpoint,
        url: URL,
        configuration: NetworkClientConfiguration
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = configuration.timeoutInterval
        endpoint.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = endpoint.body
        return request
    }

    private func applyAuthorization(
        to request: inout URLRequest,
        from endpoint: any NetworkEndpoint,
        configuration: NetworkClientConfiguration
    ) async -> Bool {
        var authType = endpoint.authorization
        if case .none = authType, let provider = configuration.authorizationProvider {
            authType = await provider.currentAuthorization()
            authType.apply(to: &request)
            return true
        }
        authType.apply(to: &request)
        return false
    }

    private func validateStatusCode(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            Logger.debug("Request successful with status \(statusCode)")
        case 403:
            Logger.warning("Forbidden request (403)")
            throw NetworkError.forbidden
        case 404:
            Logger.warning("Resource not found (404)")
            throw NetworkError.notFound
        case 408:
            Logger.warning("Request timeout (408)")
            throw NetworkError.timeout
        default:
            Logger.error("Server error with status \(statusCode)")
            throw NetworkError.serverError(statusCode: statusCode, data: data)
        }
    }

    private func decodeResponse<T: Decodable & Sendable>(
        data: Data,
        responseType: T.Type,
        configuration: NetworkClientConfiguration
    ) throws -> T {
        if data.isEmpty, responseType == EmptyResponse.self {
            guard let emptyResponse = EmptyResponse() as? T else {
                throw NetworkError.invalidData
            }
            return emptyResponse
        }

        do {
            let decoded = try configuration.decoder.decode(T.self, from: data)
            Logger.debug("Successfully decoded response as \(T.self)")
            return decoded
        } catch {
            Logger.error("Failed to decode response", error: error)
            throw NetworkError.decodingFailed(underlying: AnySendableError(error))
        }
    }

    private func handleUnauthorized<T: Decodable & Sendable>(
        endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        providerAuthApplied: Bool,
        configuration: NetworkClientConfiguration
    ) async throws -> T {
        guard let provider = configuration.authorizationProvider,
            providerAuthApplied,
            refreshAttempt < configuration.maxAuthRefreshAttempts
        else {
            Logger.warning("Cannot refresh authorization — no provider or max refresh attempts reached")
            throw NetworkError.unauthorized
        }

        Logger.info("Attempting to refresh authorization", category: .auth)
        let refreshed = await provider.refreshAuthorizationIfNeeded()
        guard refreshed else {
            Logger.error("Authorization refresh failed", category: .auth)
            throw NetworkError.authorizationRefreshFailed
        }
        Logger.info("Authorization refreshed successfully; retrying request", category: .auth)

        if configuration.retryDelay > 0 {
            Logger.debug("Waiting \(configuration.retryDelay)s before retry")
            try await Task.sleep(for: .seconds(configuration.retryDelay))
        }

        return try await performRequest(
            endpoint,
            responseType: responseType,
            refreshAttempt: refreshAttempt + 1,
            configuration: configuration
        )
    }

    private func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet:
            return .noInternetConnection
        case .timedOut:
            return .timeout
        default:
            return .underlying(AnySendableError(error))
        }
    }
}

// MARK: - Internal Helpers

/// Wraps any `Error` so it can be carried as `any Error & Sendable` in
/// ``NetworkError`` cases without requiring callers to declare Sendable
/// conformance on their own error types.
struct AnySendableError: Error, Sendable, CustomStringConvertible {
    let description: String
    let localizedDescriptionValue: String

    init(_ error: any Error) {
        self.description = String(describing: error)
        self.localizedDescriptionValue = error.localizedDescription
    }

    var localizedDescription: String { localizedDescriptionValue }
}

/// Internal wrapper that overrides an endpoint's body with pre-encoded data.
struct EncodedBodyEndpoint: NetworkEndpoint {
    let wrapped: any NetworkEndpoint
    let encodedBody: Data

    var baseURL: String { wrapped.baseURL }
    var path: String { wrapped.path }
    var method: HTTPMethod { wrapped.method }
    var queryItems: [URLQueryItem]? { wrapped.queryItems }
    var headers: [String: String]? { wrapped.headers }
    var authorization: AuthorizationType { wrapped.authorization }
    var body: Data? { encodedBody }
}
