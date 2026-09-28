import Foundation

/// Internal wrapper that overrides an endpoint's body with pre-encoded data.
///
/// Because the body is always JSON produced by the configured `JSONEncoder`,
/// a `Content-Type: application/json` header is added unless the wrapped
/// endpoint already declares a `Content-Type` header.
struct EncodedBodyEndpoint: NetworkEndpoint {
    let wrapped: any NetworkEndpoint
    let encodedBody: Data

    var baseURL: String { wrapped.baseURL }
    var path: String { wrapped.path }
    var method: HTTPMethod { wrapped.method }
    var queryItems: [URLQueryItem]? { wrapped.queryItems }
    var authorization: AuthorizationType { wrapped.authorization }
    var body: Data? { encodedBody }
    var headers: [String: String]? { HTTPHeaders.addingJSONContentTypeIfMissing(to: wrapped.headers) }
}

/// Header helpers shared by every place that attaches an encoded JSON body.
enum HTTPHeaders {
    static let contentType = "Content-Type"
    static let jsonMediaType = "application/json"

    /// Returns `headers` with `Content-Type: application/json` added, unless a
    /// `Content-Type` header (compared case-insensitively) is already present.
    static func addingJSONContentTypeIfMissing(to headers: [String: String]?) -> [String: String] {
        var headers = headers ?? [:]
        let hasContentType = headers.keys.contains { $0.caseInsensitiveCompare(contentType) == .orderedSame }
        if !hasContentType {
            headers[contentType] = jsonMediaType
        }
        return headers
    }
}
