import Foundation
internal import SwiftCommons

// MARK: - APIClient Protocol

/// A unified interface for making API requests.
///
/// Depend on this protocol when a type only needs to execute typed network
/// requests. ``NetworkClient`` is the default implementation, ``GenericRepository``
/// and ``MutationQueue`` accept any conformer, and test targets can provide
/// lightweight fakes.
///
/// Conformers implement ``response(for:responseType:)``, which returns the decoded
/// value together with its ``HTTPResponse``. Everything else is built on it:
/// ``request(_:responseType:)`` returns just the value, and the `Encodable`-body
/// overload ``response(for:body:responseType:)`` has a default implementation that
/// encodes with a plain `JSONEncoder`.
///
/// Decoding `Data` returns the raw response body without JSON decoding, and decoding
/// ``EmptyResponse`` accepts an empty body.
///
/// Example:
/// ```swift
/// struct UserService {
///     let client: any APIClient
///
///     func user(id: String) async throws -> User {
///         try await client.request(UserEndpoint(id: id), responseType: User.self)
///     }
///
///     func avatar(id: String) async throws -> Data {
///         try await client.request(AvatarEndpoint(id: id), responseType: Data.self)
///     }
/// }
/// ```
public protocol APIClient: Sendable {
    /// Performs a network request and returns the decoded value with its HTTP response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - responseType: The expected response type. `Data` returns the raw body.
    /// - Returns: The decoded value and the ``HTTPResponse`` it came from.
    /// - Throws: ``NetworkError`` if the request fails or the response cannot be decoded.
    func response<T: Decodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> DecodedResponse<T>

    /// Performs a network request with an `Encodable` JSON body and returns the decoded
    /// value with its HTTP response.
    ///
    /// The body replaces the endpoint's own ``NetworkEndpoint/body``, and a
    /// `Content-Type: application/json` header is added unless the endpoint
    /// already declares a `Content-Type` header.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected response type. `Data` returns the raw body.
    /// - Returns: The decoded value and the ``HTTPResponse`` it came from.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if `body` cannot be encoded;
    ///   otherwise the same errors as ``response(for:responseType:)``.
    func response<Body: Encodable & Sendable, T: Decodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> DecodedResponse<T>
}

// MARK: - Default Implementations

extension APIClient {
    /// Encodes `body` with a plain `JSONEncoder` and forwards to ``response(for:responseType:)``.
    ///
    /// ``NetworkClient`` overrides this to use ``NetworkClientConfiguration/encoder``.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected response type. `Data` returns the raw body.
    /// - Returns: The decoded value and the ``HTTPResponse`` it came from.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if `body` cannot be encoded;
    ///   otherwise the same errors as ``response(for:responseType:)``.
    public func response<Body: Encodable & Sendable, T: Decodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> DecodedResponse<T> {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw NetworkError.encodingFailed(underlying: AnySendableError(error))
        }
        return try await response(
            for: EncodedBodyEndpoint(wrapped: endpoint, encodedBody: encodedBody),
            responseType: responseType
        )
    }

    /// Performs a network request and returns only the decoded value.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - responseType: The expected response type. `Data` returns the raw body.
    /// - Returns: The decoded value.
    /// - Throws: The same errors as ``response(for:responseType:)``.
    public func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        try await response(for: endpoint, responseType: responseType).value
    }

    /// Performs a network request with an `Encodable` JSON body and returns only the decoded value.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint configuration for the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected response type. `Data` returns the raw body.
    /// - Returns: The decoded value.
    /// - Throws: The same errors as ``response(for:body:responseType:)``.
    public func request<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> T {
        try await response(for: endpoint, body: body, responseType: responseType).value
    }

    /// Performs a request that is expected to return no response body, returning its HTTP response.
    ///
    /// - Parameter endpoint: The endpoint describing the request.
    /// - Returns: The HTTP response: status code, headers, and empty body.
    /// - Throws: The client's transport, validation, or decoding error.
    public func response(for endpoint: any NetworkEndpoint) async throws -> HTTPResponse {
        try await response(for: endpoint, responseType: EmptyResponse.self).response
    }

    /// Performs a request with an `Encodable` JSON body that is expected to return no response body,
    /// returning its HTTP response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - body: The value to encode as the request body.
    /// - Returns: The HTTP response: status code, headers, and empty body.
    /// - Throws: The client's encoding, transport, validation, or decoding error.
    public func response<Body: Encodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        body: Body
    ) async throws -> HTTPResponse {
        try await response(for: endpoint, body: body, responseType: EmptyResponse.self).response
    }

    /// Performs a request that is expected to return no response body.
    ///
    /// - Parameter endpoint: The endpoint describing the request.
    /// - Throws: The client's transport, validation, or decoding error.
    public func request(_ endpoint: any NetworkEndpoint) async throws {
        _ = try await response(for: endpoint, responseType: EmptyResponse.self)
    }

    /// Performs a request with an `Encodable` JSON body that is expected to return no response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - body: The value to encode as the request body.
    /// - Throws: The client's encoding, transport, validation, or decoding error.
    public func request<Body: Encodable & Sendable>(_ endpoint: any NetworkEndpoint, body: Body) async throws {
        _ = try await response(for: endpoint, body: body, responseType: EmptyResponse.self)
    }
}
