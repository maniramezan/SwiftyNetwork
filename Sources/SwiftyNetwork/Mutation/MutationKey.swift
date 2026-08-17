import Foundation

/// Identifies a logical mutation for coalescing purposes.
///
/// Two mutations enqueued with the same key are treated as the same logical
/// operation: enqueuing a new value for a key that already has one pending
/// replaces it rather than queuing a second call. This is what lets rapid
/// toggling (e.g. like/unlike) collapse to a single network call for the
/// final desired state instead of replaying every intermediate one.
///
/// Choose a key that identifies the mutable resource, not the specific
/// operation -- e.g. `"like:video:42"` rather than `"like-video"` or
/// `"unlike-video"`, so both directions of the toggle coalesce together.
///
/// Example:
/// ```swift
/// let key: MutationKey = "like:video:42"
/// await queue.enqueue(request, key: key)
/// ```
public struct MutationKey: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The underlying string identity of this key.
    public let rawValue: String

    /// Creates a mutation key from a raw string.
    ///
    /// - Parameter rawValue: The string identity for this key.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a mutation key from a string literal.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}
