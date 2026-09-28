import Foundation

/// Maps HTTP status codes to ``NetworkError`` cases.
///
/// Single source of truth for status mapping, shared by ``NetworkClient`` and
/// ``RemoteDataCache``. ``NetworkClient`` handles `401` through its auth-refresh
/// path before validation runs; other callers get ``NetworkError/unauthorized``.
enum HTTPStatusValidator {
    /// Throws the ``NetworkError`` that corresponds to a non-2xx status.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code of the response.
    ///   - data: The response body, retained for ``NetworkError/serverError(statusCode:data:)``.
    /// - Throws: ``NetworkError/unauthorized``, ``NetworkError/forbidden``, ``NetworkError/notFound``,
    ///   ``NetworkError/timeout``, or ``NetworkError/serverError(statusCode:data:)``.
    static func validate(statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            Logger.debug("Request successful with status \(statusCode)")
        case 401:
            Logger.warning("Unauthorized request (401)")
            throw NetworkError.unauthorized
        case 403:
            Logger.warning("Forbidden request (403)")
            throw NetworkError.forbidden
        case 404:
            Logger.warning("Resource not found (404)")
            throw NetworkError.notFound
        case 408:
            Logger.warning("Request timeout (408)")
            throw NetworkError.timeout
        default:
            Logger.error("Server error with status \(statusCode)")
            throw NetworkError.serverError(statusCode: statusCode, data: data)
        }
    }
}
