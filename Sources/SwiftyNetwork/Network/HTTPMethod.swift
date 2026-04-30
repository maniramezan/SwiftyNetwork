import Foundation

/// Represents HTTP request methods supported by the network client.
///
/// Assign one of these values to ``NetworkEndpoint/method`` when defining an
/// endpoint. The raw value is the uppercase HTTP verb written to
/// `URLRequest.httpMethod`.
///
/// Example:
/// ```swift
/// struct CreatePostEndpoint: NetworkEndpoint {
///     let baseURL = "https://api.example.com"
///     let path = "/posts"
///     let method: HTTPMethod = .post
/// }
/// ```
public enum HTTPMethod: String, Sendable, CaseIterable {
    /// Retrieves a resource without a request body.
    case get = "GET"

    /// Retrieves headers for a resource without downloading the response body.
    case head = "HEAD"

    /// Creates a resource or submits data to be processed.
    case post = "POST"

    /// Replaces a resource with the supplied representation.
    case put = "PUT"

    /// Applies a partial update to a resource.
    case patch = "PATCH"

    /// Deletes a resource.
    case delete = "DELETE"

    /// Requests the communication options available for a resource.
    case options = "OPTIONS"
}
