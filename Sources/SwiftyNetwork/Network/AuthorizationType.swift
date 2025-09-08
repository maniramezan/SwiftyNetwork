import Foundation

/// Represents different types of HTTP authorization headers.
public enum AuthorizationType: Sendable {
    case none
    case basic(token: String)
    case bearer(token: String)
    case apiKey(key: String, header: String = "X-API-Key")
    case custom(header: String, value: String)

    /// Applies the authorization to a URL request.
    ///
    /// - Parameter request: The URL request to modify with authorization headers.
    public func apply(to request: inout URLRequest) {
        switch self {
        case .none:
            break
        case .basic(let token):
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key, let header):
            request.setValue(key, forHTTPHeaderField: header)
        case .custom(let header, let value):
            request.setValue(value, forHTTPHeaderField: header)
        }
    }
}
