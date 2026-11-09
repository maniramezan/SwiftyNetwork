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
/// A mutation request never carries credentials. Its ``authorization`` is
/// always ``AuthorizationType/none``, so the client behind the
/// ``MutationQueue`` authorizes every attempt through its
/// ``AuthorizationProvider``, including a replay after relaunch, and a `401`
/// refreshes the token instead of replaying a stale one. Configure that
/// provider on the client you pass to the queue.
///
/// - Important: Headers and bodies are persisted as given. Don't put
///   secrets in them; a durable ``MutationStore`` should still store
///   requests securely, because bodies can contain user data.
///
/// The encoded form carries a schema ``version``; decoding rejects a newer
/// version than this library understands rather than misreading it.
///
/// Example:
/// ```swift
/// let request = MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42"))
/// await queue.enqueue(request, key: "like:video:42")
/// ```
public struct MutationRequest: NetworkEndpoint, Codable, Equatable, Sendable {
    /// The schema version this library writes and the newest it can read.
    public static let version = 1

    /// The base URL for the API.
    public var baseURL: String
    /// The endpoint path.
    public var path: String
    /// The HTTP method to use.
    public var method: HTTPMethod
    /// Query parameters to append to the URL.
    public var queryItems: [URLQueryItem]?
    /// Additional HTTP headers.
    public var headers: [String: String]?
    /// The request body, pre-encoded.
    public var body: Data?

    /// Always ``AuthorizationType/none``: the queue's client authorizes mutations
    /// through its ``AuthorizationProvider``.
    public var authorization: AuthorizationType { .none }

    /// Creates a mutation request from explicit field values.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for the API.
    ///   - path: The endpoint path.
    ///   - method: The HTTP method to use.
    ///   - queryItems: Query parameters to append to the URL. Defaults to `nil`.
    ///   - headers: Additional HTTP headers. Defaults to `nil`.
    ///   - body: The request body, pre-encoded. Defaults to `nil`.
    public init(
        baseURL: String,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem]? = nil,
        headers: [String: String]? = nil,
        body: Data? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    /// Captures an existing endpoint's fields into a replayable, `Codable` value.
    ///
    /// The endpoint's ``NetworkEndpoint/authorization`` is not captured; see the
    /// type-level documentation.
    ///
    /// - Parameter endpoint: The endpoint to capture.
    public init(endpoint: any NetworkEndpoint) {
        Self.warnIfDroppingAuthorization(of: endpoint)
        self.init(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            method: endpoint.method,
            queryItems: endpoint.queryItems,
            headers: endpoint.headers,
            body: endpoint.body
        )
    }

    /// Captures an existing endpoint along with an `Encodable` body, mirroring
    /// ``NetworkClient/request(_:body:responseType:)``'s content-type behavior.
    ///
    /// A `Content-Type: application/json` header is added automatically unless
    /// the endpoint already declares one. The endpoint's
    /// ``NetworkEndpoint/authorization`` is not captured.
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
        let headers = HTTPHeaders.addingJSONContentTypeIfMissing(to: endpoint.headers)
        Self.warnIfDroppingAuthorization(of: endpoint)
        self.init(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            method: endpoint.method,
            queryItems: endpoint.queryItems,
            headers: headers,
            body: encodedBody
        )
    }

    private static func warnIfDroppingAuthorization(of endpoint: any NetworkEndpoint) {
        guard endpoint.authorization != .none else { return }
        Logger.warning(
            "MutationRequest does not persist endpoint authorization; "
                + "configure an AuthorizationProvider on the queue's client instead",
            category: .mutation
        )
    }
}

// MARK: - Codable

extension MutationRequest {
    private enum CodingKeys: String, CodingKey {
        case version, baseURL, path, method, queryItems, headers, body
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

    /// Decodes a persisted request.
    ///
    /// A payload without a `version` (written by SwiftyNetwork 1.x) is read as
    /// version 1, and any persisted `authorization` in it is ignored.
    ///
    /// - Throws: `DecodingError.dataCorrupted` when the payload's `version` is
    ///   newer than ``version``, or any error from decoding the fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "MutationRequest version \(version) is newer than supported version \(Self.version)"
            )
        }
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.path = try container.decode(String.self, forKey: .path)
        self.method = try container.decode(HTTPMethod.self, forKey: .method)
        self.queryItems = try container.decodeIfPresent([CodableQueryItem].self, forKey: .queryItems)?
            .map(\.queryItem)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        self.body = try container.decodeIfPresent(Data.self, forKey: .body)
    }

    /// Encodes the request with the current schema ``version``.
    ///
    /// - Throws: Any error from encoding the fields.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(path, forKey: .path)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(queryItems?.map(CodableQueryItem.init), forKey: .queryItems)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(body, forKey: .body)
    }
}
