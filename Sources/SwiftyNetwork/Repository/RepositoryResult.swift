import Foundation

// MARK: - Repository Result

/// An entity returned by a ``Repository``, with where it came from and when it was fetched.
///
/// Use it when the UI should treat saved data differently from fresh data, for example to show
/// "Updated 5 minutes ago" or an offline banner.
///
/// Example:
/// ```swift
/// let result = try await repository.fetchResult(
///     using: FeedEndpoint(),
///     cacheKey: "feed",
///     policy: .reloadElseReturnCache
/// )
/// show(result.value, isSaved: result.source == .cache, updated: result.timestamp)
/// ```
public struct RepositoryResult<Entity: Sendable>: Sendable {
    /// Where a ``RepositoryResult`` came from.
    public enum Source: Sendable, Equatable {
        /// The entity was just fetched from the network.
        case network

        /// The entity was read from the cache.
        case cache
    }

    /// The entity.
    public let value: Entity

    /// Whether the entity was just fetched or read from the cache.
    public let source: Source

    /// When the entity was fetched from the network. For a cached entity this is
    /// ``CacheEntry/timestamp``.
    public let timestamp: Date

    /// Creates a result, for example in a test double.
    ///
    /// - Parameters:
    ///   - value: The entity.
    ///   - source: Where the entity came from.
    ///   - timestamp: When the entity was fetched from the network. Defaults to now.
    public init(value: Entity, source: Source, timestamp: Date = Date()) {
        self.value = value
        self.source = source
        self.timestamp = timestamp
    }

    /// How long ago the entity was fetched from the network.
    ///
    /// - Parameter now: The reference instant. Defaults to now.
    /// - Returns: The time between ``timestamp`` and `now`.
    public func age(at now: Date = Date()) -> Duration {
        .seconds(now.timeIntervalSince(timestamp))
    }
}

extension RepositoryResult: Equatable where Entity: Equatable {}
