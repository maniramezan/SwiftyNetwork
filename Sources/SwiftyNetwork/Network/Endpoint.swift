import Foundation

// MARK: - URL Request Builder

extension NetworkEndpoint {
    /// Builds a `URLRequest` from the endpoint's components.
    ///
    /// This validates the base URL (scheme and host) and assembles
    /// the full request including path, query items, headers, body, and authorization.
    ///
    /// - Returns: A configured `URLRequest` ready for execution.
    /// - Throws: `URLError(.badURL)` if the base URL is invalid or missing scheme/host.
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
