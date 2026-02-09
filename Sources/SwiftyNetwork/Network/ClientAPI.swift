import Foundation

// MARK: - Endpoint Protocol

/// Defines the structure of a network endpoint with all necessary request information.
public protocol NetworkEndpoint: Sendable {
    /// The base URL for the API (e.g., "https://api.example.com").
    var baseURL: String { get }

    /// The specific path for this endpoint (e.g., "/users/123").
    var path: String { get }

    /// The HTTP method to use for this request.
    var method: HTTPMethod { get }

    /// Query parameters to append to the URL.
    var queryItems: [URLQueryItem]? { get }

    /// Additional HTTP headers to include in the request.
    var headers: [String: String]? { get }

    /// The authorization type for this endpoint.
    var authorization: AuthorizationType { get }

    /// The request body data, if applicable.
    var body: Data? { get }
}

/// Default implementations for common endpoint patterns.
extension NetworkEndpoint {
    public var queryItems: [URLQueryItem]? { nil }
    public var headers: [String: String]? { nil }
    public var authorization: AuthorizationType { .none }
    public var body: Data? { nil }
}

// MARK: - API Client Protocol

/// Provides a unified interface for making API requests.
public protocol APIClient: Sendable {
    /// Performs a network request to the specified endpoint and returns the decoded response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - responseType: The expected response type to decode to.
    /// - Returns: The decoded response of the specified type.
    /// - Throws: `NetworkError` if the request fails or response cannot be decoded.
    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T
}

// MARK: - Remote Data Source Protocol

/// Provides an abstraction for making remote network requests.
public protocol NetworkDataSource: APIClient {}

// MARK: - Network Client Configuration

/// Configuration settings for the network client.
public struct NetworkClientConfiguration: Sendable {
    /// The URL session to use for network requests.
    public var session: URLSession

    /// The JSON decoder for parsing responses.
    public var decoder: JSONDecoder

    /// The JSON encoder for creating request bodies.
    public var encoder: JSONEncoder

    /// The authorization provider for handling authentication.
    public var authorizationProvider: AuthorizationProvider?

    /// The maximum number of retry attempts for failed requests.
    public var maxRetryAttempts: Int

    /// The timeout interval for requests.
    public var timeoutInterval: TimeInterval

    /// The delay between retry attempts.
    public var retryDelay: TimeInterval

    /// Creates a new network client configuration.
    ///
    /// - Parameters:
    ///   - session: The URL session to use. Defaults to `.shared`.
    ///   - decoder: The JSON decoder to use. Defaults to a new `JSONDecoder`.
    ///   - encoder: The JSON encoder to use. Defaults to a new `JSONEncoder`.
    ///   - authorizationProvider: The authorization provider. Defaults to `nil`.
    ///   - maxRetryAttempts: Maximum retry attempts. Defaults to 1.
    ///   - timeoutInterval: Request timeout interval. Defaults to 30 seconds.
    ///   - retryDelay: The delay between retry attempts. Defaults to 1 second.
    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        authorizationProvider: AuthorizationProvider? = nil,
        maxRetryAttempts: Int = 1,
        timeoutInterval: TimeInterval = 30,
        retryDelay: TimeInterval = 1.0
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
        self.authorizationProvider = authorizationProvider
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.timeoutInterval = timeoutInterval
        self.retryDelay = retryDelay
    }
}

// MARK: - Network Client Actor

/// A thread-safe network client that handles HTTP requests with automatic retry and authorization refresh.
public actor NetworkClient: NetworkDataSource {

    private var configuration: NetworkClientConfiguration
    private var requestCount = 0

    /// Shared singleton instance with default configuration.
    ///
    /// Use this for simple apps that don't require multiple distinct configurations.
    /// For advanced usage, create separate `NetworkClient` instances with custom configurations.
    public static let shared = NetworkClient()

    /// Creates a new network client with the specified configuration.
    ///
    /// - Parameter configuration: The client configuration to use.
    public init(configuration: NetworkClientConfiguration = NetworkClientConfiguration()) {
        self.configuration = configuration
    }

    /// Updates the client's configuration atomically.
    ///
    /// - Parameter newConfiguration: The new configuration to apply.
    public func updateConfiguration(_ newConfiguration: NetworkClientConfiguration) {
        self.configuration = newConfiguration
    }

    /// Returns the current number of requests made by this client.
    public func getRequestCount() async -> Int {
        requestCount
    }

    // MARK: - Network Request Implementation

    /// Performs a network request to the provided endpoint and returns a decoded response.
    ///
    /// This is the primary public API for performing network calls with the `NetworkClient`.
    /// It will attempt authorization refresh and retries according to the configured
    /// `NetworkClientConfiguration` when applicable.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request to perform.
    ///   - responseType: The expected response `Decodable` type to decode from the server response.
    /// - Returns: A decoded instance of `responseType` representing the response payload.
    /// - Throws: `NetworkError` if the request fails, the response is invalid, or decoding fails.
    public func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        try await performRequest(endpoint, responseType: responseType, retryCount: 0)
    }

    // MARK: - Private Implementation

    private func performRequest<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type,
        retryCount: Int
    ) async throws -> T {
        requestCount += 1
        Logger.debug("Starting request to \(endpoint.baseURL)\(endpoint.path) (attempt \(retryCount + 1))")

        // Build URL
        let url = try buildURL(from: endpoint)

        // Create request
        var request = try buildURLRequest(from: endpoint, url: url)

        // Apply authorization
        try await applyAuthorization(to: &request, from: endpoint)

        // Execute request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await configuration.session.data(for: request)
        } catch let error as URLError {
            Logger.error("URL error during request", error: error)
            throw mapURLError(error)
        } catch {
            Logger.error("Unexpected error during request", error: error)
            throw error
        }

        // Validate response
        let httpResponse = try validateResponse(response)

        // Handle specific status codes
        if httpResponse.statusCode == 401 {
            return try await handleUnauthorizedResponse(
                endpoint: endpoint,
                responseType: responseType,
                retryCount: retryCount,
                originalRequest: request,
                url: url
            )
        }

        try validateStatusCode(httpResponse.statusCode, data: data)

        // Decode response
        return try decodeResponse(data: data, responseType: responseType)
    }

    private func buildURL(from endpoint: any NetworkEndpoint) throws -> URL {
        guard var urlComponents = URLComponents(string: endpoint.baseURL + endpoint.path) else {
            throw NetworkError.invalidURL(url: endpoint.baseURL + endpoint.path)
        }

        if let queryItems = endpoint.queryItems {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw NetworkError.invalidURL(url: endpoint.baseURL + endpoint.path)
        }

        return url
    }

    private func buildURLRequest(from endpoint: any NetworkEndpoint, url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = configuration.timeoutInterval

        // Apply headers
        endpoint.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Apply body
        request.httpBody = endpoint.body

        return request
    }

    private func applyAuthorization(
        to request: inout URLRequest,
        from endpoint: any NetworkEndpoint
    ) async throws {
        var authType = endpoint.authorization

        // Use provider's authorization if endpoint doesn't specify one
        if case .none = authType, let provider = configuration.authorizationProvider {
            authType = await provider.currentAuthorization()
        }

        authType.apply(to: &request)
    }

    private func validateResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        return httpResponse
    }

    private func validateStatusCode(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            Logger.debug("Request successful with status \(statusCode)")
        case 401:
            Logger.warning("Unauthorized request (401)")
            throw NetworkError.unauthorized
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
        responseType: T.Type
    ) throws -> T {
        do {
            let decoded = try configuration.decoder.decode(T.self, from: data)
            Logger.debug("Successfully decoded response as \(T.self)")
            return decoded
        } catch {
            Logger.error("Failed to decode response", error: error)
            throw NetworkError.decodingFailed(underlying: error)
        }
    }

    private func handleUnauthorizedResponse<T: Decodable & Sendable>(
        endpoint: any NetworkEndpoint,
        responseType: T.Type,
        retryCount: Int,
        originalRequest: URLRequest,
        url: URL
    ) async throws -> T {
        guard let provider = configuration.authorizationProvider,
            retryCount < configuration.maxRetryAttempts
        else {
            Logger.warning("Cannot refresh authorization - no provider or max retries reached")
            throw NetworkError.unauthorized
        }

        // Attempt to refresh authorization
        Logger.info("Attempting to refresh authorization")
        let refreshSucceeded = await provider.refreshAuthorizationIfNeeded()
        guard refreshSucceeded else {
            Logger.error("Authorization refresh failed")
            throw NetworkError.authorizationRefreshFailed
        }

        Logger.info("Authorization refreshed successfully, retrying request")
        // Retry the request with new authorization
        return try await performRequest(endpoint, responseType: responseType, retryCount: retryCount + 1)
    }

    private func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet:
            return .noInternetConnection
        case .timedOut:
            return .timeout
        default:
            return .underlying(error)
        }
    }
}
