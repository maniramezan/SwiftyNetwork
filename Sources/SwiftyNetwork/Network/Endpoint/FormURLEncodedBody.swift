import Foundation

/// An `application/x-www-form-urlencoded` request body, as HTML forms and OAuth token
/// endpoints expect.
///
/// Return its bytes and content type from an endpoint:
///
/// ```swift
/// struct TokenEndpoint: NetworkEndpoint {
///     let form: FormURLEncodedBody
///
///     let baseURL = "https://auth.example.com"
///     let path = "/oauth/token"
///     let method: HTTPMethod = .post
///     var usesAuthorizationProvider: Bool { false }
///     var headers: [String: String]? { ["Content-Type": FormURLEncodedBody.contentType] }
///     var body: Data? { form.encoded() }
/// }
///
/// let form = FormURLEncodedBody([
///     URLQueryItem(name: "grant_type", value: "refresh_token"),
///     URLQueryItem(name: "refresh_token", value: refreshToken),
/// ])
/// ```
public struct FormURLEncodedBody: Sendable, Equatable {
    /// The `Content-Type` header value for this body.
    public static let contentType = "application/x-www-form-urlencoded; charset=utf-8"

    /// The characters the URL standard leaves unescaped in a form body.
    private static let unescaped = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._"
    )

    /// The fields, in the order they are encoded. A name can repeat.
    public var items: [URLQueryItem]

    /// Creates a form body.
    ///
    /// - Parameter items: The fields, in order. An item with a `nil` value is encoded as an empty value.
    public init(_ items: [URLQueryItem] = []) {
        self.items = items
    }

    /// Encodes the fields as `name=value` pairs joined by `&`.
    ///
    /// Names and values are UTF-8 percent-encoded, with spaces written as `+`.
    ///
    /// - Returns: The body bytes.
    public func encoded() -> Data {
        let pairs = items.map { "\(Self.escape($0.name))=\(Self.escape($0.value ?? ""))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func escape(_ string: String) -> String {
        string.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unescaped) ?? "" }
            .joined(separator: "+")
    }
}
