import Foundation

/// A decoded response value together with the HTTP response it came from.
///
/// Returned by ``APIClient/response(for:responseType:)`` when you need more than the
/// decoded value: response headers such as `ETag`, `Link`, or `Location`, the exact status
/// code, or the raw body.
///
/// Example:
/// ```swift
/// let page = try await client.response(for: PostsEndpoint(page: 1), responseType: [Post].self)
/// let posts = page.value
/// let next = page.response.header("Link")
/// ```
public struct DecodedResponse<Value: Sendable>: Sendable {
    /// The decoded value.
    public let value: Value

    /// The HTTP response: status code, headers, and raw body.
    public let response: HTTPResponse

    /// Creates a decoded response, for example in a test double.
    ///
    /// - Parameters:
    ///   - value: The decoded value.
    ///   - response: The HTTP response the value was decoded from. Defaults to an empty `200`.
    public init(value: Value, response: HTTPResponse = HTTPResponse(statusCode: 200)) {
        self.value = value
        self.response = response
    }
}

extension DecodedResponse: Equatable where Value: Equatable {}
