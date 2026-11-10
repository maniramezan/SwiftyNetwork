import Foundation

// MARK: - Typed Endpoint

/// A ``NetworkEndpoint`` that names the type its response decodes to.
///
/// Conform to it when an endpoint always returns the same type, so call sites use
/// ``APIClient/send(_:)`` and don't repeat `responseType:`. Use ``EmptyResponse`` for an
/// endpoint with no response body, and `Data` for the raw body.
///
/// Example:
/// ```swift
/// struct UserEndpoint: TypedEndpoint {
///     typealias Response = User
///
///     let id: String
///
///     let baseURL = "https://api.example.com"
///     var path: String { "/users/\(id)" }
///     let method: HTTPMethod = .get
/// }
///
/// let user = try await client.send(UserEndpoint(id: "123"))
/// ```
public protocol TypedEndpoint: NetworkEndpoint {
    /// The type the response body decodes to.
    associatedtype Response: Decodable & Sendable
}

extension APIClient {
    /// Performs a request and returns the value decoded as the endpoint's ``TypedEndpoint/Response``.
    ///
    /// To read the status code or response headers too, call
    /// ``response(for:responseType:)`` with `E.Response.self`.
    ///
    /// - Parameter endpoint: The endpoint describing the request and its response type.
    /// - Returns: The decoded response.
    /// - Throws: The same errors as ``response(for:responseType:)``.
    @discardableResult
    public func send<E: TypedEndpoint>(_ endpoint: E) async throws -> E.Response {
        try await response(for: endpoint, responseType: E.Response.self).value
    }

    /// Performs a request with an `Encodable` JSON body and returns the value decoded as the
    /// endpoint's ``TypedEndpoint/Response``.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request and its response type.
    ///   - body: The value to encode as the request body.
    /// - Returns: The decoded response.
    /// - Throws: The same errors as ``response(for:body:responseType:)``.
    @discardableResult
    public func send<E: TypedEndpoint, Body: Encodable & Sendable>(
        _ endpoint: E,
        body: Body
    ) async throws -> E.Response {
        try await response(for: endpoint, body: body, responseType: E.Response.self).value
    }
}
