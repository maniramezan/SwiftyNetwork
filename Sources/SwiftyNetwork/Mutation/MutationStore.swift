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

    /// Removes any persisted request for `key`.
    ///
    /// Called once a mutation has succeeded or failed permanently.
    ///
    /// - Parameter key: The logical mutation to clear.
    func remove(for key: MutationKey) async

    /// Returns every key with a currently persisted request.
    ///
    /// A durable implementation uses this on app launch to discover and
    /// replay mutations that were pending when the process was killed.
    func allKeys() async -> [MutationKey]
}
