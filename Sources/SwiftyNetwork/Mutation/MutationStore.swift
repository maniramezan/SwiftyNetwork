import Foundation

/// Pluggable persistence for pending mutations.
///
/// ``MutationQueue`` reads and writes through this protocol so the consuming
/// app can choose in-memory (lost on process death, the default -- see
/// ``InMemoryMutationStore``) or durable persistence (survives relaunch and
/// can replay pending mutations, e.g. a SwiftData- or file-backed
/// implementation the app provides).
///
/// Because ``MutationRequest`` is `Codable`, a durable conformance can
/// serialize it directly. Implementations must be safe to call concurrently
/// from multiple mutation keys at once.
public protocol MutationStore: Sendable {
    /// Persists `request` as the current desired state for `key`, replacing
    /// any value already stored for that key.
    ///
    /// This is the coalescing point: enqueuing a new value for a key with a
    /// pending mutation should overwrite it rather than append.
    ///
    /// - Parameters:
    ///   - request: The mutation to persist.
    ///   - key: The logical mutation this request belongs to.
    func save(_ request: MutationRequest, for key: MutationKey) async

    /// Returns the currently persisted request for `key`, if any.
    ///
    /// - Parameter key: The logical mutation to look up.
    func load(for key: MutationKey) async -> MutationRequest?

    /// Removes any persisted request for `key`, unconditionally.
    ///
    /// - Parameter key: The logical mutation to clear.
    func remove(for key: MutationKey) async

    /// Atomically removes `request` for `key`, but only if it is still the
    /// currently persisted value for that key.
    ///
    /// ``MutationQueue`` calls this after a request finishes (successfully
    /// or with a permanent failure) instead of a separate load-then-remove,
    /// so a coalesced replacement saved while that request was in flight is
    /// never discarded out from under the caller that enqueued it. A
    /// conforming type must implement this as a single, non-suspending
    /// check-and-remove -- composing ``load(for:)`` and ``remove(for:)``
    /// from outside reintroduces the race this method exists to close.
    ///
    /// - Parameters:
    ///   - request: The value the caller just finished processing.
    ///   - key: The logical mutation to clear.
    /// - Returns: `true` if `request` was still current and was removed;
    ///   `false` if the stored value had already changed, in which case
    ///   nothing is removed.
    func removeIfCurrent(_ request: MutationRequest, for key: MutationKey) async -> Bool

    /// Returns every key with a currently persisted request.
    ///
    /// A durable implementation uses this on app launch to discover
    /// mutations that were pending when the process was killed; pass the
    /// result to ``MutationQueue/resumePendingMutations()`` to replay them.
    func allKeys() async -> [MutationKey]
}
