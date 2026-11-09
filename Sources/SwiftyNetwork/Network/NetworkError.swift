import Foundation
import SwiftCommons

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

    /// The server returned `429 Too Many Requests`.
    ///
    /// ``HTTPErrorResponse/retryAfter`` carries the parsed `Retry-After` header, and the
    /// response headers carry rate-limit details such as `X-RateLimit-Remaining`.
    ///
    /// - Parameter response: The rejected response.
    case tooManyRequests(HTTPErrorResponse)

    /// The server returned `401 Unauthorized`, and authorization could not be refreshed.
    ///
    /// - Parameter response: The rejected response.
    case unauthorized(HTTPErrorResponse)

    /// The server returned `403 Forbidden`.
    ///
    /// ``NetworkClient`` never refreshes authorization for a `403`.
    ///
    /// - Parameter response: The rejected response.
    case forbidden(HTTPErrorResponse)

    /// The server returned `404 Not Found`.
    ///
    /// - Parameter response: The rejected response.
    case notFound(HTTPErrorResponse)

    /// The server returned a `4xx` status that has no more specific case
    /// (anything other than `401`, `403`, `404`, `408`, and `429`).
    ///
    /// The request itself was rejected; retrying it unchanged will not help.
    ///
    /// - Parameter response: The rejected response.
    case clientError(HTTPErrorResponse)

    /// The server returned a `5xx` status.
    ///
    /// For a `503`, ``HTTPErrorResponse/retryAfter`` carries the parsed `Retry-After` header.
    ///
    /// - Parameter response: The failed response.
    case serverError(HTTPErrorResponse)

    /// The server returned a non-2xx status outside `4xx` and `5xx`, such as an
    /// unfollowed `3xx` redirect.
    ///
    /// - Parameter response: The unexpected response.
    case unexpectedStatus(HTTPErrorResponse)

    /// The request timed out at the transport layer or the server returned `408 Request Timeout`.
    ///
    /// - Parameter response: The `408` response, or `nil` when the timeout happened at the
    ///   transport layer, where there is no response.
    case timeout(HTTPErrorResponse?)

    /// The transport layer reported that no internet connection is available.
    case noInternetConnection

    /// The response body could not be decoded as the requested `Decodable` type.
    case decodingFailed(underlying: any Error & Sendable)

    /// The request body could not be encoded from the supplied `Encodable` value.
    case encodingFailed(underlying: any Error & Sendable)

    /// The configured ``AuthorizationProvider`` could not supply authorization, so the
    /// request was not sent.
    ///
    /// - Parameter underlying: The error thrown by
    ///   ``AuthorizationProvider/currentAuthorization()``.
    case authorizationUnavailable(underlying: any Error & Sendable)

    /// The configured ``AuthorizationProvider`` failed to refresh credentials after a `401`.
    ///
    /// - Parameter underlying: The error thrown by
    ///   ``AuthorizationProvider/refreshAuthorization(rejecting:)``.
    case authorizationRefreshFailed(underlying: any Error & Sendable)

    /// A lower-level error that does not map to a more specific ``NetworkError`` case.
    case underlying(any Error & Sendable)

    /// A localized description suitable for logs and basic user-facing error text.
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "The server response was invalid or malformed."
        case .clientError(let response):
            return "The request was rejected with status code \(response.statusCode)."
        case .serverError(let response):
            return "Server error with status code \(response.statusCode)."
        case .unexpectedStatus(let response):
            return "Unexpected response status code \(response.statusCode)."
        case .tooManyRequests:
            return "Too many requests. Please try again later."
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
        case .authorizationUnavailable(let underlying):
            return "No authorization credentials are available: \(underlying.localizedDescription)"
        case .authorizationRefreshFailed(let underlying):
            return "Failed to refresh authorization credentials: \(underlying.localizedDescription)"
        case .underlying(let error):
            return "An underlying error occurred: \(error.localizedDescription)"
        }
    }

    /// The HTTP response behind this error, with its status code, headers, and body.
    ///
    /// Available for every case that comes from an HTTP status: ``unauthorized(_:)``,
    /// ``forbidden(_:)``, ``notFound(_:)``, ``timeout(_:)`` (for a `408`),
    /// ``tooManyRequests(_:)``, ``clientError(_:)``, ``serverError(_:)``, and
    /// ``unexpectedStatus(_:)``. Use it to tell apart failures that share a status code, for
    /// example by decoding an API error `code` from ``HTTPErrorResponse/body``, reading
    /// ``HTTPErrorResponse/wwwAuthenticate``, or reading rate-limit headers with
    /// ``HTTPErrorResponse/header(_:)``.
    ///
    /// - Returns: The response, or `nil` for cases that did not come from an HTTP status.
    public var response: HTTPErrorResponse? {
        switch self {
        case .unauthorized(let response), .forbidden(let response), .notFound(let response),
            .tooManyRequests(let response), .clientError(let response), .serverError(let response),
            .unexpectedStatus(let response):
            return response
        case .timeout(let response):
            return response
        case .invalidURL, .invalidResponse, .noInternetConnection, .decodingFailed,
            .encodingFailed, .authorizationUnavailable, .authorizationRefreshFailed, .underlying:
            return nil
        }
    }

    /// The HTTP status code behind this error, or `nil` when it did not come from an HTTP status.
    public var statusCode: Int? {
        response?.statusCode
    }

    /// How long the server asked the client to wait before retrying.
    ///
    /// Equivalent to `response?.retryAfter`: non-`nil` only for a `429` or `503` that
    /// carried a valid `Retry-After` header.
    public var retryAfter: Duration? {
        response?.retryAfter
    }

    /// Maps a transport-level `URLError` to the corresponding ``NetworkError``.
    ///
    /// Shared by every part of SwiftyNetwork that talks to `URLSession`
    /// directly (``NetworkClient`` and ``RemoteDataCache``), so transport
    /// failures are classified identically everywhere in the package.
    ///
    /// Connectivity-loss codes (a dropped connection, cellular data disabled,
    /// roaming off) map to ``noInternetConnection`` so they are classified as
    /// transient and retried by ``MutationQueue``. Other codes keep the original
    /// `URLError` in ``underlying(_:)`` so callers can still inspect `code`.
    ///
    /// Callers translate `URLError.cancelled` into `CancellationError` first
    /// (see `transportError(_:)`) when the calling task was cancelled; a
    /// `.cancelled` that reaches this function, such as a rejected TLS pin,
    /// stays in ``underlying(_:)``.
    ///
    /// - Parameter error: The transport-level error to map.
    /// - Returns: The corresponding ``NetworkError`` case.
    static func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .noInternetConnection
        case .timedOut:
            return .timeout(nil)
        default:
            return .underlying(error)
        }
    }
}

extension NetworkError {
    /// Maps any error thrown by `URLSession` to what SwiftyNetwork rethrows.
    ///
    /// Task cancellation surfaces as `CancellationError`, the same error a
    /// cancelled retry or auth-refresh wait throws, so callers have one shape
    /// to check. `URLSession` reports a cancelled task as `URLError.cancelled`,
    /// but so does a rejected TLS pin; only the former is translated, by
    /// checking `Task.isCancelled`.
    ///
    /// - Parameter error: The error thrown by `URLSession`.
    /// - Returns: `CancellationError` for task cancellation, otherwise a ``NetworkError``.
    static func transportError(_ error: any Error) -> any Error {
        if error is CancellationError {
            return error
        }
        guard let urlError = error as? URLError else {
            return NetworkError.underlying(AnySendableError(error))
        }
        if urlError.code == .cancelled, Task.isCancelled {
            return CancellationError()
        }
        return mapURLError(urlError)
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
    /// A `4xx` status without a more specific classification.
    case clientError(statusCode: Int)
    /// A `5xx` status.
    case serverError(statusCode: Int)
    /// A non-2xx status outside `4xx` and `5xx`.
    case unexpectedStatus(statusCode: Int)
    /// The server returned `429 Too Many Requests`.
    case tooManyRequests
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
    /// The configured ``AuthorizationProvider`` could not supply authorization.
    case authorizationUnavailable
    /// The configured ``AuthorizationProvider`` failed to refresh credentials.
    case authorizationRefreshFailed
    /// A lower-level error with no more specific classification.
    case underlying

    /// Whether an error of this classification is generally worth retrying.
    ///
    /// `true` for timeouts, missing connectivity, `429` rate limiting, and 5xx
    /// server errors -- conditions a retry can plausibly resolve. `false` for
    /// everything else: 4xx client errors (other than what ``NetworkClient``
    /// already handles via auth refresh), a response that is not HTTP (usually
    /// a broken server or proxy), and encoding/decoding failures, since a retry
    /// can't change their outcome.
    public var isTransient: Bool {
        switch self {
        case .timeout, .noConnection, .tooManyRequests, .serverError:
            return true
        case .invalidURL, .invalidResponse, .clientError, .unexpectedStatus, .unauthorized, .forbidden, .notFound,
            .decodingFailed, .encodingFailed, .authorizationUnavailable, .authorizationRefreshFailed, .underlying:
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
        case .clientError(let response):
            return .clientError(statusCode: response.statusCode)
        case .serverError(let response):
            return .serverError(statusCode: response.statusCode)
        case .unexpectedStatus(let response):
            return .unexpectedStatus(statusCode: response.statusCode)
        case .tooManyRequests:
            return .tooManyRequests
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
        case .authorizationUnavailable:
            return .authorizationUnavailable
        case .authorizationRefreshFailed:
            return .authorizationRefreshFailed
        case .underlying:
            return .underlying
        }
    }

    /// Whether this error is generally worth retrying.
    ///
    /// The single source of truth for transient-error classification --
    /// ``MutationRetryPolicy/defaultShouldRetry(_:)`` and any custom retry
    /// or telemetry logic should use this instead of re-deriving it.
    /// Equivalent to `classification.isTransient`.
    public var isTransient: Bool {
        classification.isTransient
    }
}
