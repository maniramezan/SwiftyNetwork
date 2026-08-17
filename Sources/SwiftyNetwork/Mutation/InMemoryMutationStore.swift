import Foundation

/// Default, non-durable ``MutationStore`` backed by an in-memory dictionary.
///
/// Pending mutations are lost if the process is killed. This is the
/// appropriate choice for forgivable mutations where losing a rare in-flight
/// call to a crash or force-quit is acceptable, and is what ``MutationQueue``
/// uses when no store is supplied.
///
/// Example:
/// ```swift
/// let queue = MutationQueue(client: NetworkClient.shared, store: InMemoryMutationStore())
/// ```
public actor InMemoryMutationStore: MutationStore {
    private var requestsByKey: [MutationKey: MutationRequest] = [:]

    /// Creates an empty in-memory store.
    public init() {}

    public func save(_ request: MutationRequest, for key: MutationKey) async {
        requestsByKey[key] = request
    }

    public func load(for key: MutationKey) async -> MutationRequest? {
        requestsByKey[key]
    }

    public func remove(for key: MutationKey) async {
        requestsByKey.removeValue(forKey: key)
    }

    public func allKeys() async -> [MutationKey] {
        Array(requestsByKey.keys)
    }
}
