import Foundation

/// Comprehensive error types that can occur during network operations.
///
/// ``NetworkClient`` throws these errors for URL construction failures,
/// transport failures, HTTP status failures, authorization refresh failures, and
/// JSON encoding or decoding failures. Match specific cases when you need
/// user-facing recovery behavior.
///
/// Example:
/// ```swift
/// do {
///     let user = try await client.request(endpoint, responseType: User.self)
/// } catch NetworkError.unauthorized {
///     showSignIn()
/// } catch NetworkError.noInternetConnection {
///     showOfflineMessage()
/// } catch {
///     showGenericError(error.localizedDescription)
/// }
/// ```
public enum NetworkError: Error, LocalizedError, Sendable {
    /// The endpoint's base URL, path, or query items could not be converted into a valid URL.
    case invalidURL(url: String)

    /// The server returned a response that was not an `HTTPURLResponse`.
    case invalidResponse

    /// The response body was invalid for the expected successful response shape.
    case invalidData

    /// The server returned an unhandled non-2xx HTTP status code.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code returned by the server.
    ///   - data: The response body, if one was returned.
    case serverError(statusCode: Int, data: Data?)

    /// The server returned `401 Unauthorized`, and authorization could not be refreshed.
    case unauthorized

    /// The server returned `403 Forbidden`.
    case forbidden

    /// The server returned `404 Not Found`.
    case notFound

    /// The request timed out at the transport layer or the server returned `408 Request Timeout`.
    case timeout

    /// The transport layer reported that no internet connection is available.
    case noInternetConnection

    /// The response body could not be decoded as the requested `Decodable` type.
    case decodingFailed(underlying: any Error & Sendable)

    /// The request body could not be encoded from the supplied `Encodable` value.
    case encodingFailed(underlying: any Error & Sendable)

    /// The configured ``AuthorizationProvider`` failed to refresh credentials after a `401`.
    case authorizationRefreshFailed

    /// A lower-level error that does not map to a more specific ``NetworkError`` case.
    case underlying(any Error & Sendable)

    /// A localized description suitable for logs and basic user-facing error text.
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "The server response was invalid or malformed."
        case .invalidData:
            return "The response data was invalid or corrupted."
        case .serverError(let statusCode, _):
            return "Server error with status code \(statusCode)."
        case .unauthorized:
            return "Unauthorized access. Please check your credentials."
        case .forbidden:
            return "Access forbidden. You don't have permission to access this resource."
        case .notFound:
            return "The requested resource was not found."
        case .timeout:
            return "The request timed out. Please try again."
        case .noInternetConnection:
            return "No internet connection available."
        case .decodingFailed(let underlying):
            return "Failed to decode response: \(underlying.localizedDescription)"
        case .encodingFailed(let underlying):
            return "Failed to encode request: \(underlying.localizedDescription)"
        case .authorizationRefreshFailed:
            return "Failed to refresh authorization credentials."
        case .underlying(let error):
            return "An underlying error occurred: \(error.localizedDescription)"
        }
    }

    /// The underlying error data for server errors, if available.
    public var serverErrorData: Data? {
        if case .serverError(_, let data) = self {
            return data
        }
        return nil
    }
}
