import Foundation

/// Strategies for applying authorization headers to outgoing requests.
///
/// Use this enum either directly on an endpoint via ``NetworkEndpoint/authorization``
/// or indirectly through an ``AuthorizationProvider`` configured on
/// ``NetworkClientConfiguration``. SwiftyNetwork applies authorization immediately
/// before the request is sent.
///
/// Example:
/// ```swift
/// struct PrivateEndpoint: NetworkEndpoint {
///     let baseURL = "https://api.example.com"
///     let path = "/profile"
///     let method: HTTPMethod = .get
///     let authorization: AuthorizationType = .bearer(token: "access-token")
/// }
/// ```
public enum AuthorizationType: Sendable, Equatable {
    /// No authorization header is added.
    case none

    /// HTTP Basic authentication using a username and password.
    ///
    /// The username and password are combined and base64-encoded automatically.
    case basic(username: String, password: String)

    /// HTTP Basic authentication using a pre-encoded credential string.
    ///
    /// Use this when you already have a base64-encoded `user:password` string.
    case basicEncoded(credential: String)

    /// OAuth 2.0 / Bearer token authentication.
    case bearer(token: String)

    /// Static API key sent in the supplied header.
    ///
    /// - Parameters:
    ///   - key: The API key value to send.
    ///   - header: The header name. Defaults to `X-API-Key`.
    case apiKey(key: String, header: String = "X-API-Key")

    /// A fully custom authorization header.
    ///
    /// Use this for schemes not represented by the built-in cases, such as
    /// vendor-specific token prefixes.
    case custom(header: String, value: String)

    /// Applies the authorization to a URL request.
    ///
    /// The method mutates the supplied request by setting the relevant header.
    /// For ``AuthorizationType/none``, the request is left unchanged.
    ///
    /// Example:
    /// ```swift
    /// if let url = URL(string: "https://api.example.com") {
    ///     var request = URLRequest(url: url)
    ///     AuthorizationType.apiKey(key: "abc123").apply(to: &request)
    /// }
    /// ```
    ///
    /// - Parameter request: The URL request to modify.
    public func apply(to request: inout URLRequest) {
        switch self {
        case .none:
            break
        case .basic(let username, let password):
            let credential = "\(username):\(password)"
            let encoded = Data(credential.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .basicEncoded(let credential):
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key, let header):
            request.setValue(key, forHTTPHeaderField: header)
        case .custom(let header, let value):
            request.setValue(value, forHTTPHeaderField: header)
        }
    }
}
