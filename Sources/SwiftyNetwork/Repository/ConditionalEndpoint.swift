import Foundation

/// Internal wrapper that makes a request conditional on the cached entity tag.
///
/// It adds `If-None-Match`, replacing one the wrapped endpoint declares, so the server can
/// answer `304 Not Modified` instead of sending the body again.
struct ConditionalEndpoint: NetworkEndpoint {
    static let ifNoneMatch = "If-None-Match"
    static let entityTag = "ETag"

    let wrapped: any NetworkEndpoint
    let entityTag: String

    var baseURL: String { wrapped.baseURL }
    var path: String { wrapped.path }
    var method: HTTPMethod { wrapped.method }
    var queryItems: [URLQueryItem]? { wrapped.queryItems }
    var authorization: AuthorizationType { wrapped.authorization }
    var usesAuthorizationProvider: Bool { wrapped.usesAuthorizationProvider }
    var body: Data? { wrapped.body }
    var operationName: String? { wrapped.operationName }
    var timeout: Duration? { wrapped.timeout }
    var cachePolicy: URLRequest.CachePolicy? { wrapped.cachePolicy }
    var isIdempotent: Bool { wrapped.isIdempotent }
    var headers: [String: String]? {
        var headers = (wrapped.headers ?? [:]).filter {
            $0.key.caseInsensitiveCompare(Self.ifNoneMatch) != .orderedSame
        }
        headers[Self.ifNoneMatch] = entityTag
        return headers
    }
}
