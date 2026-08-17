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
public enum AuthorizationType: Sendable, Equatable, Codable {
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

// MARK: - Codable

extension AuthorizationType {
    private enum CodingKeys: String, CodingKey {
        case kind, username, password, credential, token, key, header, value
    }

    /// Discriminator persisted alongside a case's associated values.
    ///
    /// `AuthorizationType` cannot derive `Codable` automatically because its
    /// cases carry associated values; this keeps the wire format stable and
    /// explicit rather than relying on enum-case ordering.
    private enum Kind: String, Codable {
        case none, basic, basicEncoded, bearer, apiKey, custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .basic:
            self = .basic(
                username: try container.decode(String.self, forKey: .username),
                password: try container.decode(String.self, forKey: .password)
            )
        case .basicEncoded:
            self = .basicEncoded(credential: try container.decode(String.self, forKey: .credential))
        case .bearer:
            self = .bearer(token: try container.decode(String.self, forKey: .token))
        case .apiKey:
            self = .apiKey(
                key: try container.decode(String.self, forKey: .key),
                header: try container.decode(String.self, forKey: .header)
            )
        case .custom:
            self = .custom(
                header: try container.decode(String.self, forKey: .header),
                value: try container.decode(String.self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .basic(let username, let password):
            try container.encode(Kind.basic, forKey: .kind)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        case .basicEncoded(let credential):
            try container.encode(Kind.basicEncoded, forKey: .kind)
            try container.encode(credential, forKey: .credential)
        case .bearer(let token):
            try container.encode(Kind.bearer, forKey: .kind)
            try container.encode(token, forKey: .token)
        case .apiKey(let key, let header):
            try container.encode(Kind.apiKey, forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(header, forKey: .header)
        case .custom(let header, let value):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(header, forKey: .header)
            try container.encode(value, forKey: .value)
        }
    }
}
