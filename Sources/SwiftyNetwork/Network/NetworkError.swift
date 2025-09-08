import Foundation

/// Comprehensive error types that can occur during network operations.
public enum NetworkError: Error, LocalizedError, Sendable {
    case invalidURL(url: String)
    case invalidResponse
    case invalidData
    case serverError(statusCode: Int, data: Data?)
    case unauthorized
    case forbidden
    case notFound
    case timeout
    case noInternetConnection
    case decodingFailed(underlying: Error)
    case encodingFailed(underlying: Error)
    case authorizationRefreshFailed
    case underlying(Error)

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
