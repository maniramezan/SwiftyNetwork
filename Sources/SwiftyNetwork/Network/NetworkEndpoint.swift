import Foundation

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
public protocol NetworkEndpoint: Sendable {
    /// The base URL for the API (e.g. `"https://api.example.com"`).
    ///
    /// May include a path prefix; trailing slashes are normalized.
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
    var authorization: AuthorizationType { get }

    /// The request body, pre-encoded. Defaults to `nil`.
    ///
    /// Use ``NetworkClient/request(_:body:responseType:)`` to encode bodies via
    /// the configured `JSONEncoder` instead of pre-encoding here.
    var body: Data? { get }
}

extension NetworkEndpoint {
    /// Default query parameters for endpoints that do not need a query string.
    public var queryItems: [URLQueryItem]? { nil }

    /// Default headers for endpoints that do not need custom HTTP headers.
    public var headers: [String: String]? { nil }

    /// Default authorization strategy for endpoints that rely on client-level auth or no auth.
    public var authorization: AuthorizationType { .none }

    /// Default request body for endpoints that do not send pre-encoded data.
    public var body: Data? { nil }
}

// MARK: - URL Builder

extension NetworkEndpoint {
    /// Builds a `URLRequest` for this endpoint.
    ///
    /// Validates that the base URL has an `http`/`https` scheme and a non-empty
    /// host, normalizes slashes between ``baseURL`` and ``path``, and applies
    /// query items, headers, body, and authorization.
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
        guard let scheme = components.scheme,
            ["http", "https"].contains(scheme.lowercased()),
            let host = components.host,
            !host.isEmpty
        else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }

        let basePath = components.path.trimmingTrailingSlashes
        let endpointPath = path.ensuringLeadingSlash
        components.path = basePath + endpointPath

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL(url: baseURL + path)
        }
        return url
    }
}

extension String {
    fileprivate var trimmingTrailingSlashes: String {
        var result = self
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    fileprivate var ensuringLeadingSlash: String {
        if isEmpty { return "" }
        return "/" + drop(while: { $0 == "/" })
    }
}
