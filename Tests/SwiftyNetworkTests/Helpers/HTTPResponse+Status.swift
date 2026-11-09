import Foundation

@testable import SwiftyNetwork

extension HTTPResponse {
    /// A response snapshot for building ``NetworkError`` values in tests.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - retryAfter: Seconds to send as a delta-seconds `Retry-After` header, if any.
    ///   - body: The response body.
    static func status(_ statusCode: Int, retryAfter: Int? = nil, body: Data? = nil) -> HTTPResponse {
        let headers = retryAfter.map { [RetryAfter.headerName: String($0)] } ?? [:]
        return HTTPResponse(statusCode: statusCode, headers: headers, body: body ?? Data())
    }
}
