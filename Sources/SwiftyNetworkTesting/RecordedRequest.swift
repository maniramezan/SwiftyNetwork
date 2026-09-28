import Foundation
import SwiftyNetwork

/// A snapshot of an endpoint received by ``MockAPIClient``.
///
/// Captures the wire-level fields so tests can assert on what would have been
/// sent without depending on the endpoint's concrete type.
public struct RecordedRequest: Sendable, Equatable {
    /// The endpoint's base URL.
    public let baseURL: String
    /// The endpoint path.
    public let path: String
    /// The HTTP method.
    public let method: HTTPMethod
    /// Query parameters, if any.
    public let queryItems: [URLQueryItem]?
    /// Endpoint-declared headers, if any.
    public let headers: [String: String]?
    /// Endpoint-declared authorization.
    public let authorization: AuthorizationType
    /// The pre-encoded request body, if any.
    public let body: Data?

    /// Captures `endpoint`'s fields.
    ///
    /// - Parameter endpoint: The endpoint to snapshot.
    public init(_ endpoint: any NetworkEndpoint) {
        self.baseURL = endpoint.baseURL
        self.path = endpoint.path
        self.method = endpoint.method
        self.queryItems = endpoint.queryItems
        self.headers = endpoint.headers
        self.authorization = endpoint.authorization
        self.body = endpoint.body
    }

    /// Decodes ``body`` as JSON.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - decoder: The decoder to use.
    /// - Returns: The decoded body, or `nil` when there is no body.
    /// - Throws: Any decoding error.
    public func decodedBody<Value: Decodable>(
        as type: Value.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value? {
        guard let body else { return nil }
        return try decoder.decode(type, from: body)
    }
}
