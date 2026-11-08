import Foundation

/// The status code, headers, and body of an HTTP response that ``NetworkClient`` rejected.
///
/// Attached to ``NetworkError/unauthorized(response:)`` and
/// ``NetworkError/forbidden(response:)`` so callers can tell apart failures that share a
/// status code, for example a `401` whose body carries `"code": "not_authenticated"`
/// (a token refresh can fix it) from one that does not.
///
/// The body is the raw server payload and can contain user-specific data. SwiftyNetwork never
/// logs it; do the same in your own logging.
///
/// Example:
/// ```swift
/// do {
///     _ = try await client.request(endpoint, responseType: Profile.self)
/// } catch let error as NetworkError {
///     if let response = error.response {
///         let challenge = response.header("WWW-Authenticate")
///         let apiError = try? response.decodeBody(APIErrorBody.self)
///     }
/// }
/// ```
public struct HTTPErrorResponse: Sendable, Equatable {
    /// The HTTP status code of the response.
    public let statusCode: Int

    /// The response headers, keyed as the server sent them.
    ///
    /// Prefer ``header(_:)`` for lookups, because HTTP header names are case-insensitive.
    public let headers: [String: String]

    /// The raw response body. Empty when the server sent none.
    public let body: Data

    /// Creates a response snapshot.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - headers: The response headers.
    ///   - body: The raw response body.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Returns the value of the header named `name`, matching case-insensitively.
    ///
    /// - Parameter name: The header name, for example `"WWW-Authenticate"`.
    /// - Returns: The header value, or `nil` when the response has no such header.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The `WWW-Authenticate` challenge header, if the server sent one.
    public var wwwAuthenticate: String? {
        header("WWW-Authenticate")
    }

    /// Decodes the body as JSON.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode.
    ///   - decoder: The decoder to use. Defaults to a plain `JSONDecoder`.
    /// - Returns: The decoded value.
    /// - Throws: A `DecodingError` when the body is empty or is not valid for `type`.
    public func decodeBody<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: body)
    }

    init(_ response: HTTPURLResponse, body: Data) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        self.init(statusCode: response.statusCode, headers: headers, body: body)
    }
}
