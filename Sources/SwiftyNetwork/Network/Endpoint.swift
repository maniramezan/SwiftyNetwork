import Foundation

/// Describes a network endpoint with all components needed to build a URLRequest.
public protocol Endpoint {
    /// Base URL string, e.g., "https://api.example.com"
    var baseURL: String { get }
    /// Path component to append to the base URL, e.g., "/v1/items"
    var path: String { get }
    /// HTTP method to use for the request.
    var method: HTTPMethod { get }
    /// Optional query items to append to the URL.
    var queryItems: [URLQueryItem]? { get }
    /// Optional HTTP headers for the request.
    var headers: [String: String]? { get }
    /// Authorization strategy for the request.
    var authorization: AuthorizationType { get }
    /// Optional HTTP body data.
    var body: Data? { get }
}

extension Endpoint {
    /// Builds a URLRequest from the endpoint components.
    public func makeURLRequest() throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        guard let scheme = components.scheme,
            ["http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty
        else {
            throw URLError(.badURL)
        }
        components.path = components.path.appending(path)
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
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
        authorization.apply(to: &request)
        return request
    }
}
