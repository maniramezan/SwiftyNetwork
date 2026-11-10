import Foundation

/// The status code, headers, and body of an HTTP response.
///
/// A successful request returns it in ``DecodedResponse/response`` (see
/// ``APIClient/response(for:responseType:)``), so callers can read headers such as `ETag`,
/// `Link`, or rate-limit counters. It is also attached to every ``NetworkError`` case that
/// comes from an HTTP status, so callers can tell apart failures that share a status code, for
/// example a `401` whose body carries `"code": "not_authenticated"` (a token refresh can fix it)
/// from one that does not.
///
/// The body is the raw server payload and can contain user-specific data. SwiftyNetwork never
/// logs it; do the same in your own logging. The `description` and `debugDescription` are
/// redacted so that interpolating the response, or a ``NetworkError`` that carries it, into a log
/// line reveals only the status code, header names, and body size, never header values or body bytes.
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
public struct HTTPResponse: Sendable, Equatable {
    /// The HTTP status code of the response.
    public let statusCode: Int

    /// The response headers, keyed as the server sent them.
    ///
    /// Prefer ``header(_:)`` for lookups, because HTTP header names are case-insensitive.
    public let headers: [String: String]

    /// The raw response body. Empty when the server sent none.
    public let body: Data

    /// How long the server asked the client to wait before retrying.
    ///
    /// Parsed from the `Retry-After` header, in either its delta-seconds or HTTP-date form, when
    /// the status is `429 Too Many Requests` or `503 Service Unavailable` (RFC 9110 §10.2.3).
    /// `nil` for other statuses and when the header is absent or malformed.
    /// ``NetworkRetryPolicy`` and ``MutationRetryPolicy`` honor it.
    public let retryAfter: Duration?

    /// The statuses on which `Retry-After` is meaningful for an error (RFC 9110 §10.2.3).
    static let retryAfterStatusCodes: Set<Int> = [429, 503]

    /// Creates a response snapshot.
    ///
    /// ``retryAfter`` is parsed from `headers` for a `429` or `503`.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - headers: The response headers.
    ///   - body: The raw response body.
    ///   - receivedAt: The instant the response arrived, used to resolve an HTTP-date
    ///     `Retry-After`. Defaults to now.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data(), receivedAt: Date = Date()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        if Self.retryAfterStatusCodes.contains(statusCode),
            let value = headers.first(where: {
                $0.key.caseInsensitiveCompare(RetryAfter.headerName) == .orderedSame
            })?.value
        {
            self.retryAfter = RetryAfter.parse(value, now: receivedAt)
        } else {
            self.retryAfter = nil
        }
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

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    /// A redacted summary: the status code, the sorted header names, and the body size in bytes.
    ///
    /// Header values and body bytes are omitted because they can carry credentials,
    /// cookies, or personal data.
    public var description: String {
        let names = headers.keys.sorted().joined(separator: ", ")
        return "HTTPResponse(statusCode: \(statusCode), headers: [\(names)], body: \(body.count) bytes)"
    }

    /// The same redacted summary as ``description``.
    public var debugDescription: String {
        description
    }
}
