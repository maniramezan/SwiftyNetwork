import Foundation

/// Represents HTTP request methods supported by the network client.
public enum HTTPMethod: String, Sendable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"
}
