import Foundation

// MARK: - APIClient Protocol

/// A unified interface for making API requests.
///
/// Depend on this protocol when a type only needs to execute typed network
/// requests. ``NetworkClient`` is the default implementation, and test targets can
/// provide lightweight fakes.
///
/// Example:
/// ```swift
/// struct UserService {
///     let client: any APIClient
///
///     func user(id: String) async throws -> User {
///         try await client.request(UserEndpoint(id: id), responseType: User.self)
///     }
/// }
/// ```
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
///
/// Use this when constructing ``GenericRepository``. The protocol does not add
/// requirements beyond ``APIClient``; it communicates intent that a client is safe
/// to use as a repository's remote data source.
public protocol NetworkDataSource: APIClient {}

// MARK: - Convenience API

extension APIClient {
    /// Performs a request that is expected to return no response body.
    ///
    /// - Parameter endpoint: The endpoint describing the request.
    /// - Throws: The client's transport, validation, or decoding error.
    public func request(_ endpoint: any NetworkEndpoint) async throws {
        _ = try await request(endpoint, responseType: EmptyResponse.self)
    }
}
