import Foundation

/// Maps HTTP responses to ``NetworkError`` cases.
///
/// Single source of truth for status mapping, shared by ``NetworkClient`` and
/// ``RemoteDataCache``. ``NetworkClient`` handles `401` through its auth-refresh
/// path before validation runs; other callers get ``NetworkError/unauthorized(_:)``.
///
/// Every thrown error carries the ``HTTPErrorResponse`` snapshot, which parses
/// `Retry-After` itself, so no caller can forget either.
enum HTTPStatusValidator {
    /// Throws the ``NetworkError`` that corresponds to a non-2xx response.
    ///
    /// - Parameters:
    ///   - httpResponse: The response whose status code and headers are inspected.
    ///   - data: The response body, retained on the thrown error.
    /// - Throws: ``NetworkError/unauthorized(_:)``, ``NetworkError/forbidden(_:)``,
    ///   ``NetworkError/notFound(_:)``, ``NetworkError/timeout(_:)``,
    ///   ``NetworkError/tooManyRequests(_:)``, ``NetworkError/clientError(_:)``,
    ///   ``NetworkError/serverError(_:)``, or ``NetworkError/unexpectedStatus(_:)``.
    static func validate(_ httpResponse: HTTPURLResponse, data: Data) throws {
        let statusCode = httpResponse.statusCode
        if (200..<300).contains(statusCode) {
            Logger.debug("Request successful with status \(statusCode)")
            return
        }
        throw error(for: HTTPErrorResponse(httpResponse, body: data))
    }

    /// Returns the ``NetworkError`` for a non-2xx response snapshot.
    static func error(for response: HTTPErrorResponse) -> NetworkError {
        let statusCode = response.statusCode
        switch statusCode {
        case 401:
            Logger.warning("Unauthorized request (401)")
            return .unauthorized(response)
        case 403:
            Logger.warning("Forbidden request (403)")
            return .forbidden(response)
        case 404:
            Logger.warning("Resource not found (404)")
            return .notFound(response)
        case 408:
            Logger.warning("Request timeout (408)")
            return .timeout(response)
        case 429:
            Logger.warning("Too many requests (429)")
            return .tooManyRequests(response)
        case 400..<500:
            Logger.warning("Client error with status \(statusCode)")
            return .clientError(response)
        case 500..<600:
            Logger.error("Server error with status \(statusCode)")
            return .serverError(response)
        default:
            Logger.error("Unexpected status \(statusCode)")
            return .unexpectedStatus(response)
        }
    }
}
