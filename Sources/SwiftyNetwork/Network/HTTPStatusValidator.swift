import Foundation

/// Maps HTTP responses to ``NetworkError`` cases.
///
/// Single source of truth for status mapping, shared by ``NetworkClient`` and
/// ``RemoteDataCache``. ``NetworkClient`` handles `401` through its auth-refresh
/// path before validation runs; other callers get ``NetworkError/unauthorized(response:)``.
///
/// The validator reads the headers itself, so no caller can forget to attach the
/// ``HTTPErrorResponse`` snapshot or the parsed `Retry-After`.
enum HTTPStatusValidator {
    /// The statuses on which `Retry-After` is meaningful for an error (RFC 9110 §10.2.3).
    private static let retryAfterStatusCodes: Set<Int> = [429, 503]

    /// Throws the ``NetworkError`` that corresponds to a non-2xx response.
    ///
    /// - Parameters:
    ///   - httpResponse: The response whose status code and headers are inspected.
    ///   - data: The response body, retained on the thrown error.
    /// - Throws: ``NetworkError/unauthorized(response:)``, ``NetworkError/forbidden(response:)``,
    ///   ``NetworkError/notFound``, ``NetworkError/timeout``,
    ///   ``NetworkError/tooManyRequests(retryAfter:data:response:)``, or
    ///   ``NetworkError/serverError(statusCode:data:retryAfter:response:)``. Every error that
    ///   carries a payload also carries the full ``HTTPErrorResponse`` snapshot.
    static func validate(_ httpResponse: HTTPURLResponse, data: Data) throws {
        let statusCode = httpResponse.statusCode
        switch statusCode {
        case 200..<300:
            Logger.debug("Request successful with status \(statusCode)")
        case 401:
            Logger.warning("Unauthorized request (401)")
            throw NetworkError.unauthorized(response: HTTPErrorResponse(httpResponse, body: data))
        case 403:
            Logger.warning("Forbidden request (403)")
            throw NetworkError.forbidden(response: HTTPErrorResponse(httpResponse, body: data))
        case 404:
            Logger.warning("Resource not found (404)")
            throw NetworkError.notFound
        case 408:
            Logger.warning("Request timeout (408)")
            throw NetworkError.timeout
        case 429:
            Logger.warning("Too many requests (429)")
            throw NetworkError.tooManyRequests(
                retryAfter: RetryAfter.parse(from: httpResponse),
                data: data,
                response: HTTPErrorResponse(httpResponse, body: data)
            )
        default:
            Logger.error("Server error with status \(statusCode)")
            let retryAfter = retryAfterStatusCodes.contains(statusCode) ? RetryAfter.parse(from: httpResponse) : nil
            throw NetworkError.serverError(
                statusCode: statusCode,
                data: data,
                retryAfter: retryAfter,
                response: HTTPErrorResponse(httpResponse, body: data)
            )
        }
    }
}
