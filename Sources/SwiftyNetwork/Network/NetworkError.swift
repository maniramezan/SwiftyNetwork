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

    /// Maps a transport-level `URLError` to the corresponding ``NetworkError``.
    ///
    /// Shared by every part of SwiftyNetwork that talks to `URLSession`
    /// directly (``NetworkClient`` and ``RemoteDataCache``), so transport
    /// failures are classified identically everywhere in the package.
    ///
    /// - Parameter error: The transport-level error to map.
    /// - Returns: The corresponding ``NetworkError`` case.
    static func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet:
            return .noInternetConnection
        case .timedOut:
            return .timeout
        default:
            return .underlying(AnySendableError(error))
        }
    }
}

// MARK: - Retry Classification

/// A coarse-grained classification of a ``NetworkError``, useful for
/// telemetry tagging (e.g. span attributes) without re-deriving it from
/// scratch on every call site.
///
/// This is the same classification ``NetworkError/isTransient`` is built
/// from, so retry policies and observability code share a single source of
/// truth instead of each hand-rolling their own `classify(error:)`.
public enum NetworkErrorClassification: Sendable, Equatable {
    /// The URL, path, or query items could not be constructed.
    case invalidURL
    /// The response was not a well-formed HTTP response.
    case invalidResponse
    /// The response body was invalid for the expected shape.
    case invalidData
    /// A non-2xx HTTP status the client doesn't have a more specific case for.
    case serverError(statusCode: Int)
    /// The server returned `401` and authorization could not be refreshed.
    case unauthorized
    /// The server returned `403`.
    case forbidden
    /// The server returned `404`.
    case notFound
    /// The request timed out.
    case timeout
    /// No internet connection was available.
    case noConnection
    /// The response body failed to decode.
    case decodingFailed
    /// The request body failed to encode.
    case encodingFailed
    /// The configured ``AuthorizationProvider`` failed to refresh credentials.
    case authorizationRefreshFailed
    /// A lower-level error with no more specific classification.
    case underlying

    /// Whether an error of this classification is generally worth retrying.
    ///
    /// `true` for timeouts, missing connectivity, malformed responses, and
    /// 5xx server errors -- conditions a retry can plausibly resolve.
    /// `false` for everything else, including 4xx client errors (other than
    /// what ``NetworkClient`` already handles via auth refresh) and
    /// encoding/decoding failures, since a retry can't change their outcome.
    public var isTransient: Bool {
        switch self {
        case .timeout, .noConnection, .invalidResponse:
            return true
        case .serverError(let statusCode):
            return statusCode >= 500
        case .invalidURL, .invalidData, .unauthorized, .forbidden, .notFound, .decodingFailed, .encodingFailed,
            .authorizationRefreshFailed, .underlying:
            return false
        }
    }
}

extension NetworkError {
    /// This error's coarse-grained ``NetworkErrorClassification``.
    ///
    /// Example:
    /// ```swift
    /// catch let error as NetworkError {
    ///     span.setAttribute("error.category", value: "\(error.classification)")
    /// }
    /// ```
    public var classification: NetworkErrorClassification {
        switch self {
        case .invalidURL:
            return .invalidURL
        case .invalidResponse:
            return .invalidResponse
        case .invalidData:
            return .invalidData
        case .serverError(let statusCode, _):
            return .serverError(statusCode: statusCode)
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .forbidden
        case .notFound:
            return .notFound
        case .timeout:
            return .timeout
        case .noInternetConnection:
            return .noConnection
        case .decodingFailed:
            return .decodingFailed
        case .encodingFailed:
            return .encodingFailed
        case .authorizationRefreshFailed:
            return .authorizationRefreshFailed
        case .underlying:
            return .underlying
        }
    }

    /// Whether this error is generally worth retrying.
    ///
    /// The single source of truth for transient-error classification --
    /// ``MutationRetryPolicy/defaultIsRetryable(_:)`` and any custom retry
    /// or telemetry logic should use this instead of re-deriving it.
    /// Equivalent to `classification.isTransient`.
    public var isTransient: Bool {
        classification.isTransient
    }
}
