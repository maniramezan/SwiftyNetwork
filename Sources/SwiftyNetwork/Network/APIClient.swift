import Foundation

// MARK: - APIClient Protocol

/// A unified interface for making API requests.
public protocol APIClient: Sendable {
    /// Performs a network request and returns the decoded response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - responseType: The expected response type to decode to.
    /// - Returns: The decoded response of the specified type.
    /// - Throws: ``NetworkError`` if the request fails or the response cannot be decoded.
    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T
}

// MARK: - NetworkDataSource Protocol

/// Marker protocol for types that can serve as the network layer of a repository.
public protocol NetworkDataSource: APIClient {}
