import Foundation
internal import SwiftCommons

// MARK: - Endpoint Protocol

/// Defines the structure of a network endpoint with all necessary request information.
///
/// Conform to this protocol to describe an HTTP request in a type-safe way.
/// Most properties have sensible defaults, so a minimal endpoint only needs
/// ``baseURL``, ``path``, and ``method``.
///
/// Example:
/// ```swift
/// struct UserEndpoint: NetworkEndpoint {
///     let id: String
///
///     let baseURL = "https://api.example.com"
///     var path: String { "/users/\(id)" }
///     let method: HTTPMethod = .get
///     var queryItems: [URLQueryItem]? { [URLQueryItem(name: "include", value: "profile")] }
/// }
/// ```
///
/// Every endpoint names its own host, because one app often talks to several: its own API, a
/// CDN, a third-party service. To avoid repeating a base URL, and anything else the endpoints of
/// one API share, declare it once in a protocol that refines this one:
///
/// ```swift
/// protocol ExampleAPIEndpoint: NetworkEndpoint {}
///
/// extension ExampleAPIEndpoint {
///     var baseURL: String { AppEnvironment.current.apiBaseURL }
///     var headers: [String: String]? { ["Accept": "application/json"] }
/// }
///
/// struct UserEndpoint: ExampleAPIEndpoint {
///     let id: String
///
///     var path: String { "/users/\(id)" }
///     let method: HTTPMethod = .get
/// }
/// ```
///
/// An endpoint that forgets its base URL then fails to compile instead of failing when sent.
///
/// To have the endpoint name its response type, so call sites don't repeat it, conform to
/// ``TypedEndpoint`` instead.
public protocol NetworkEndpoint: Sendable {
    /// The base URL for the API (e.g. `"https://api.example.com"`).
    ///
    /// May include a path prefix; trailing slashes are normalized. For a complete URL the
    /// server handed you, return it here with an empty ``path``.
    var baseURL: String { get }

    /// The endpoint path (e.g. `"/users/123"`). Leading slashes are normalized.
    var path: String { get }

    /// The HTTP method to use for this request.
    var method: HTTPMethod { get }

    /// Query parameters to append to the URL. Defaults to `nil`.
    var queryItems: [URLQueryItem]? { get }

    /// Additional HTTP headers to include in the request. Defaults to `nil`.
    var headers: [String: String]? { get }

    /// The authorization to apply to this endpoint. Defaults to ``AuthorizationType/none``.
    ///
    /// With ``AuthorizationType/none``, ``NetworkClient`` uses its configured
    /// ``AuthorizationProvider`` instead, unless ``usesAuthorizationProvider`` is `false`.
    var authorization: AuthorizationType { get }

    /// Whether ``NetworkClient`` may authorize this endpoint with its configured
    /// ``AuthorizationProvider``. Defaults to `true`.
    ///
    /// Return `false` for endpoints that must not carry the user's credentials, such as sign-in,
    /// sign-up, or token refresh, public endpoints, and other services' URLs. The request is then sent
    /// with only this endpoint's own ``authorization``, and a `401` throws
    /// ``NetworkError/unauthorized(_:)`` without a refresh.
    ///
    /// The refresh endpoint must opt out if the provider's refresh calls the same client. Otherwise it
    /// is sent with the expired token, and a `401` from it would ask the provider to refresh again
    /// while the provider is still refreshing.
    ///
    /// Example:
    /// ```swift
    /// struct RefreshTokenEndpoint: NetworkEndpoint {
    ///     let baseURL = "https://api.example.com"
    ///     let path = "/oauth/token"
    ///     let method: HTTPMethod = .post
    ///     var usesAuthorizationProvider: Bool { false }
    /// }
    /// ```
    var usesAuthorizationProvider: Bool { get }

    /// The request body, pre-encoded. Defaults to `nil`.
    ///
    /// Use ``NetworkClient/request(_:body:responseType:)`` to encode bodies via
    /// the configured `JSONEncoder` instead of pre-encoding here.
    var body: Data? { get }

    /// A stable, low-cardinality name for this operation, such as `"videos.list"`. Defaults to `nil`.
    ///
    /// ``NetworkClient`` passes it to ``NetworkInstrumentation`` in every event for the request,
    /// so telemetry can group requests by operation instead of by URL, which carries
    /// identifiers and query values. Don't put user data in it.
    var operationName: String? { get }

    /// The timeout for this request, or `nil` to use ``NetworkClientConfiguration/timeout``.
    /// Defaults to `nil`.
    ///
    /// Set a longer timeout for a slow operation, such as one that generates content on the
    /// server, without raising it for every request.
    var timeout: Duration? { get }

    /// The `URLRequest` cache policy for this request, or `nil` to use the session's.
    /// Defaults to `nil`.
    ///
    /// When the client's session has a `URLCache`, return `.reloadIgnoringLocalCacheData` for
    /// a request that must reach the server, such as a pull-to-refresh or a balance check.
    var cachePolicy: URLRequest.CachePolicy? { get }

    /// Whether sending this request more than once has the same effect as sending it once.
    /// Defaults to ``HTTPMethod/isIdempotent`` of ``method``.
    ///
    /// ``NetworkRetryPolicy`` retries only idempotent requests. Return `true` for a `POST`
    /// the server deduplicates, such as a sync or an upsert, to make it retryable; return
    /// `false` for a `PUT` or `DELETE` that must not be replayed.
    var isIdempotent: Bool { get }
}

extension NetworkEndpoint {
    /// Default query parameters for endpoints that do not need a query string.
    public var queryItems: [URLQueryItem]? { nil }

    /// Default headers for endpoints that do not need custom HTTP headers.
    public var headers: [String: String]? { nil }

    /// Default authorization strategy for endpoints that rely on client-level auth or no auth.
    public var authorization: AuthorizationType { .none }

    /// Returns `true`, so the client's ``AuthorizationProvider`` authorizes the endpoint.
    public var usesAuthorizationProvider: Bool { true }

    /// Default request body for endpoints that do not send pre-encoded data.
    public var body: Data? { nil }

    /// Returns `nil`, so instrumentation events carry no operation name.
    public var operationName: String? { nil }

    /// Returns `nil`, so the client's ``NetworkClientConfiguration/timeout`` applies.
    public var timeout: Duration? { nil }

    /// Returns `nil`, so the session's cache policy applies.
    public var cachePolicy: URLRequest.CachePolicy? { nil }

    /// Returns ``HTTPMethod/isIdempotent`` of ``method``.
    public var isIdempotent: Bool { method.isIdempotent }
}

// MARK: - URL Builder

extension NetworkEndpoint {
    /// Builds a `URLRequest` for this endpoint.
    ///
    /// Validates that the base URL has an `http`/`https` scheme and a non-empty
    /// host, normalizes slashes between ``baseURL`` and ``path``, and applies
    /// query items, headers, body, ``cachePolicy``, ``timeout``, and authorization.
    ///
    /// - Returns: A configured `URLRequest`.
    /// - Throws: ``NetworkError/invalidURL(url:)`` if the URL cannot be constructed.
    ///
    /// Example:
    /// ```swift
    /// let request = try UserEndpoint(id: "123").makeURLRequest()
    /// print(request.url?.absoluteString ?? "")
    /// ```
    public func makeURLRequest() throws -> URLRequest {
        let url = try EndpointURLBuilder.url(baseURL: baseURL, path: path, queryItems: queryItems)
        var request = makeUnauthenticatedURLRequest(url: url)
        authorization.apply(to: &request)
        return request
    }

    /// Shared assembly; provider authorization is applied separately by the client.
    func makeUnauthenticatedURLRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let cachePolicy {
            request.cachePolicy = cachePolicy
        }
        if let timeout {
            request.timeoutInterval = timeout.timeInterval
        }
        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body {
            request.httpBody = body
        }
        return request
    }
}

// MARK: - Internal URL Builder

/// Single source of truth for assembling endpoint URLs.
enum EndpointURLBuilder {
    /// Builds a URL from a base URL, a path, and optional query items.
    ///
    /// - The base URL must use `http` or `https` and have a non-empty host.
    /// - Trailing slashes on the base path and leading slashes on the endpoint
    ///   path are normalized so the join always produces exactly one slash.
    /// - An empty `queryItems` array is treated the same as `nil`.
    static func url(
        baseURL: String,
        path: String,
        queryItems: [URLQueryItem]?
    ) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }
        guard let scheme = components.scheme else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }
        let lowerScheme = scheme.lowercased()
        guard lowerScheme == "http" || lowerScheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }

        let basePath = components.path.trimmingSuffix(while: { $0 == "/" })
        let endpointPath =
            path.isEmpty ? "" : String(path.trimmingPrefix(while: { $0 == "/" })).ensuringStarts(with: "/")
        components.path = basePath + endpointPath

        // Keep the base URL's query byte for byte: decoding and re-encoding it would turn a
        // presigned URL's `%2B` into `+` and `%2F` into `/`, which invalidates its signature.
        if let queryItems, !queryItems.isEmpty {
            var added = URLComponents()
            added.queryItems = queryItems
            let existingQuery = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
            components.percentEncodedQuery = [existingQuery, added.percentEncodedQuery]
                .compactMap { $0 }
                .joined(separator: "&")
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }
        return url
    }
}
