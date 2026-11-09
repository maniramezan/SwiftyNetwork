import Foundation

/// An HTTP request method.
///
/// Assign one of these values to ``NetworkEndpoint/method`` when defining an
/// endpoint. The ``rawValue`` is the method token written to
/// `URLRequest.httpMethod`, exactly as given (HTTP method names are case-sensitive).
///
/// `HTTPMethod` is a struct rather than an enum so you can send methods that
/// SwiftyNetwork does not predefine, such as WebDAV's `PROPFIND` or the
/// `QUERY` method, without a library update:
///
/// ```swift
/// extension HTTPMethod {
///     static let propfind: HTTPMethod = "PROPFIND"
/// }
/// ```
///
/// Example:
/// ```swift
/// struct CreatePostEndpoint: NetworkEndpoint {
///     let baseURL = "https://api.example.com"
///     let path = "/posts"
///     let method: HTTPMethod = .post
/// }
/// ```
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The method token, such as `"GET"`.
    public let rawValue: String

    /// Creates a method from its token.
    ///
    /// - Parameter rawValue: The method token, such as `"PROPFIND"`. It is sent exactly as given.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a method from a string literal, such as `let method: HTTPMethod = "PROPFIND"`.
    ///
    /// - Parameter value: The method token.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// The method token.
    public var description: String { rawValue }

    /// Retrieves a resource without a request body.
    public static let get = HTTPMethod(rawValue: "GET")

    /// Retrieves headers for a resource without downloading the response body.
    public static let head = HTTPMethod(rawValue: "HEAD")

    /// Creates a resource or submits data to be processed.
    public static let post = HTTPMethod(rawValue: "POST")

    /// Replaces a resource with the supplied representation.
    public static let put = HTTPMethod(rawValue: "PUT")

    /// Applies a partial update to a resource.
    public static let patch = HTTPMethod(rawValue: "PATCH")

    /// Deletes a resource.
    public static let delete = HTTPMethod(rawValue: "DELETE")

    /// Requests the communication options available for a resource.
    public static let options = HTTPMethod(rawValue: "OPTIONS")
}
