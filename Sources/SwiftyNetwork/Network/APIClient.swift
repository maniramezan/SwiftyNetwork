import Foundation
import SwiftCommons

// MARK: - APIClient Protocol

/// A unified interface for making API requests.
///
/// Depend on this protocol when a type only needs to execute typed network
/// requests. ``NetworkClient`` is the default implementation, ``GenericRepository``
/// and ``MutationQueue`` accept any conformer, and test targets can provide
/// lightweight fakes.
///
/// Conformers implement ``request(_:responseType:)``. The `Encodable`-body
/// overload ``request(_:body:responseType:)`` has a default implementation that
/// encodes with a plain `JSONEncoder` and forwards to it.
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

    /// Performs a network request with an `Encodable` JSON body and returns the decoded response.
    ///
    /// The body replaces the endpoint's own ``NetworkEndpoint/body``, and a
    /// `Content-Type: application/json` header is added unless the endpoint
    /// already declares a `Content-Type` header.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected response type to decode to.
    /// - Returns: The decoded response of the specified type.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if `body` cannot be encoded;
    ///   otherwise the same errors as ``request(_:responseType:)``.
    func request<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> T
}

// MARK: - Default Implementations

extension APIClient {
    /// Encodes `body` with a plain `JSONEncoder` and forwards to ``request(_:responseType:)``.
    ///
    /// ``NetworkClient`` overrides this to use ``NetworkClientConfiguration/encoder``.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected response type to decode to.
    /// - Returns: The decoded response of the specified type.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if `body` cannot be encoded;
    ///   otherwise the same errors as ``request(_:responseType:)``.
    public func request<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> T {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw NetworkError.encodingFailed(underlying: AnySendableError(error))
        }
        return try await request(
            EncodedBodyEndpoint(wrapped: endpoint, encodedBody: encodedBody),
            responseType: responseType
        )
    }

    /// Performs a request that is expected to return no response body.
    ///
    /// - Parameter endpoint: The endpoint describing the request.
    /// - Throws: The client's transport, validation, or decoding error.
    public func request(_ endpoint: any NetworkEndpoint) async throws {
        _ = try await request(endpoint, responseType: EmptyResponse.self)
    }

    /// Performs a request with an `Encodable` JSON body that is expected to return no response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - body: The value to encode as the request body.
    /// - Throws: The client's encoding, transport, validation, or decoding error.
    public func request<Body: Encodable & Sendable>(_ endpoint: any NetworkEndpoint, body: Body) async throws {
        _ = try await request(endpoint, body: body, responseType: EmptyResponse.self)
    }
}
