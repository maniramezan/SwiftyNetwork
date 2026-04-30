import Foundation

/// A response type for successful requests that do not return a body.
///
/// Use ``EmptyResponse`` with endpoints that return `204 No Content`, an empty
/// `200 OK` response, or any successful response where the body should be ignored.
/// ``NetworkClient/request(_:)`` uses this type internally for its no-return-value
/// overload.
///
/// Example:
/// ```swift
/// struct DeleteUserEndpoint: NetworkEndpoint {
///     let baseURL = "https://api.example.com"
///     let path = "/users/123"
///     let method: HTTPMethod = .delete
/// }
///
/// let client = NetworkClient()
/// try await client.request(DeleteUserEndpoint())
/// ```
public struct EmptyResponse: Decodable, Sendable, Equatable {
    /// Creates an empty response value.
    ///
    /// You usually do not need to construct this directly; use
    /// ``NetworkClient/request(_:)`` for requests that return no body.
    public init() {}
}
