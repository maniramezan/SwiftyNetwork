import Foundation

/// A `Codable`, replayable description of a single network mutation.
///
/// Unlike an ad-hoc `NetworkEndpoint` conformance (which can capture
/// non-serializable context in its properties), `MutationRequest` is a plain
/// value type holding only wire-representable fields. That's what makes it
/// possible for a durable ``MutationStore`` to persist "which endpoint plus
/// what body" to disk and replay it after a process relaunch, instead of
/// trying to serialize a Swift closure.
///
/// Conforms to ``NetworkEndpoint`` directly, so it can be executed by any
/// ``APIClient`` without an adapter.
///
/// - Important: ``AuthorizationType`` cases can carry secrets (bearer
///   tokens, API keys, basic-auth credentials). A durable ``MutationStore``
///   implementation is responsible for storing the encoded request securely
///   (e.g. Keychain-backed storage on Apple platforms) -- SwiftyNetwork does
///   not encrypt persisted mutations itself.
///
/// Example:
/// ```swift
/// let request = MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42"))
/// await queue.enqueue(request, key: "like:video:42")
/// ```
public struct MutationRequest: NetworkEndpoint, Codable, Equatable, Sendable {
    public var baseURL: String
    public var path: String
    public var method: HTTPMethod
    public var queryItems: [URLQueryItem]?
    public var headers: [String: String]?
    public var authorization: AuthorizationType
    public var body: Data?

    /// Creates a mutation request from explicit field values.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for the API.
    ///   - path: The endpoint path.
    ///   - method: The HTTP method to use.
    ///   - queryItems: Query parameters to append to the URL. Defaults to `nil`.
    ///   - headers: Additional HTTP headers. Defaults to `nil`.
    ///   - authorization: The authorization to apply. Defaults to ``AuthorizationType/none``.
    ///   - body: The request body, pre-encoded. Defaults to `nil`.
    public init(
        baseURL: String,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem]? = nil,
        headers: [String: String]? = nil,
        authorization: AuthorizationType = .none,
        body: Data? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.headers = headers
        self.authorization = authorization
        self.body = body
    }

    /// Captures an existing endpoint's fields into a replayable, `Codable` value.
    ///
    /// - Parameter endpoint: The endpoint to capture.
    public init(endpoint: any NetworkEndpoint) {
        self.init(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            method: endpoint.method,
            queryItems: endpoint.queryItems,
            headers: endpoint.headers,
            authorization: endpoint.authorization,
            body: endpoint.body
        )
    }

    /// Captures an existing endpoint along with an `Encodable` body, mirroring
    /// ``NetworkClient/request(_:body:responseType:)``'s content-type behavior.
    ///
    /// A `Content-Type: application/json` header is added automatically unless
    /// the endpoint already declares one.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to capture.
    ///   - encodableBody: The value to encode as the request body.
    ///   - encoder: The encoder to use. Defaults to a plain `JSONEncoder`.
    /// - Throws: An error if `encodableBody` cannot be encoded.
    public init<Body: Encodable>(
        endpoint: any NetworkEndpoint,
        encodableBody: Body,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let encodedBody = try encoder.encode(encodableBody)
        var headers = endpoint.headers ?? [:]
        let hasContentType = headers.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
        if !hasContentType {
            headers["Content-Type"] = "application/json"
        }
        self.init(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            method: endpoint.method,
            queryItems: endpoint.queryItems,
            headers: headers,
            authorization: endpoint.authorization,
            body: encodedBody
        )
    }
}

// MARK: - Codable

extension MutationRequest {
    private enum CodingKeys: String, CodingKey {
        case baseURL, path, method, queryItems, headers, authorization, body
    }

    /// `URLQueryItem` does not conform to `Codable` on all supported
    /// platforms, so query items are persisted as this plain name/value pair.
    private struct CodableQueryItem: Codable {
        let name: String
        let value: String?

        init(_ item: URLQueryItem) {
            self.name = item.name
            self.value = item.value
        }

        var queryItem: URLQueryItem { URLQueryItem(name: name, value: value) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.path = try container.decode(String.self, forKey: .path)
        self.method = try container.decode(HTTPMethod.self, forKey: .method)
        self.queryItems = try container.decodeIfPresent([CodableQueryItem].self, forKey: .queryItems)?
            .map(\.queryItem)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        self.authorization = try container.decode(AuthorizationType.self, forKey: .authorization)
        self.body = try container.decodeIfPresent(Data.self, forKey: .body)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(path, forKey: .path)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(queryItems?.map(CodableQueryItem.init), forKey: .queryItems)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encode(authorization, forKey: .authorization)
        try container.encodeIfPresent(body, forKey: .body)
    }
}
