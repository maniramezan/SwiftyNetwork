import Foundation

/// A response type for successful requests that do not return a body.
public struct EmptyResponse: Decodable, Sendable, Equatable {
    /// Creates an empty response value.
    public init() {}
}
