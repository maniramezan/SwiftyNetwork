import Foundation

/// A fire-and-forget queue for "forgivable" mutations, with background retry,
/// pluggable persistence, and coalescing by key.
///
/// Establishes a general pattern: API calls that mutate state on behalf of a
/// user action (liking a post, updating a setting) don't need to block the
/// UI on the network round trip, and transient failures shouldn't be silently
/// dropped just because ``NetworkClient`` itself doesn't retry them. Enqueue
/// a mutation and return immediately; execution, retry, and status reporting
/// happen in the background.
///
/// `MutationQueue` only reports outcomes via ``events()`` / ``status(for:)``
/// -- it does not manage UI state. Optimistic updates and rollback on
/// permanent failure remain the caller's responsibility.
///
/// Example:
/// ```swift
/// let queue = MutationQueue(client: NetworkClient.shared)
///
/// // Fire-and-forget: returns immediately, retries in the background.
/// let request = MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42"))
/// await queue.enqueue(request, key: "like:video:42")
///
/// // Rapid toggling coalesces to the latest desired state.
/// let undo = MutationRequest(endpoint: UnlikeVideoEndpoint(videoID: "42"))
/// await queue.enqueue(undo, key: "like:video:42")
///
/// for await event in await queue.events() where event.key == "like:video:42" {
///     switch event.status {
///     case .succeeded: break
///     case .failed: showLikeFailedError()
///     default: break
///     }
/// }
/// ```
public actor MutationQueue {

    /// A status change for a specific mutation key, as emitted by ``events()``.
    public struct MutationEvent: Sendable, Equatable {
        public let key: MutationKey
        public let status: MutationStatus
    }

    private let client: any APIClient
    private let store: any MutationStore
    private let retryPolicy: MutationRetryPolicy

    private var latestStatusByKey: [MutationKey: MutationStatus] = [:]
    private var processingTaskByKey: [MutationKey: Task<Void, Never>] = [:]
    private var eventContinuations: [UUID: AsyncStream<MutationEvent>.Continuation] = [:]

    /// Creates a mutation queue.
    ///
    /// - Parameters:
    ///   - client: The client used to execute mutations. Defaults to ``NetworkClient/shared``.
    ///   - store: Where pending mutations are persisted. Defaults to a fresh ``InMemoryMutationStore``.
    ///   - retryPolicy: Governs retry attempts and backoff. Defaults to ``MutationRetryPolicy/default``.
    public init(
        client: any APIClient = NetworkClient.shared,
        store: any MutationStore = InMemoryMutationStore(),
        retryPolicy: MutationRetryPolicy = .default
    ) {
        self.client = client
        self.store = store
        self.retryPolicy = retryPolicy
    }

    /// Enqueues a mutation and returns immediately; the network call and any
    /// retries happen on a background task.
    ///
    /// If a mutation is already pending or in flight for `key`, this replaces
    /// its desired end state. An execution already in flight is not
    /// cancelled (it can't be, mid-network-call) but its result is discarded
    /// in favor of processing the newly enqueued value next, so only the
    /// latest state is ever the *last* thing sent to the server.
    ///
    /// - Parameters:
    ///   - request: The mutation to execute.
    ///   - key: The logical mutation this belongs to, for coalescing.
    public func enqueue(_ request: MutationRequest, key: MutationKey) async {
        await store.save(request, for: key)
        setStatus(.pending, for: key)
        startProcessingIfNeeded(for: key)
    }

    /// The most recently observed status for `key`, if it has ever been enqueued.
    ///
    /// - Parameter key: The logical mutation to look up.
    public func status(for key: MutationKey) -> MutationStatus? {
        latestStatusByKey[key]
    }

    /// Resumes processing for every mutation currently persisted in the
    /// configured ``MutationStore``.
    ///
    /// A durable store can hold mutations that were pending when the process
    /// was last killed; those are otherwise never picked back up, since
    /// nothing else calls ``MutationStore/allKeys()``. Call this once at
    /// startup after constructing a queue backed by a durable store (safe to
    /// call unconditionally, including with ``InMemoryMutationStore``, which
    /// is simply empty on a fresh launch).
    public func resumePendingMutations() async {
        for key in await store.allKeys() {
            setStatus(.pending, for: key)
            startProcessingIfNeeded(for: key)
        }
    }

    /// A stream of status changes across all mutation keys.
    ///
    /// The stream only emits events that occur after it is created; it does
    /// not replay history. Subscribe before enqueueing if you need to observe
    /// a mutation's ``MutationStatus/pending`` state. The stream never
    /// finishes on its own -- cancel the consuming task when you're done.
    public func events() -> AsyncStream<MutationEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MutationEvent>.makeStream()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(id) }
        }
        return stream
    }

    // MARK: - Processing

    private func startProcessingIfNeeded(for key: MutationKey) {
        guard processingTaskByKey[key] == nil else { return }
        processingTaskByKey[key] = Task { [weak self] in
            await self?.process(key: key)
        }
    }

    private func process(key: MutationKey) async {
        defer { processingTaskByKey[key] = nil }

        var attempt = 0
        while !Task.isCancelled {
            guard let request = await store.load(for: key) else { return }

            do {
                _ = try await client.request(request, responseType: EmptyResponse.self)

                if await store.removeIfCurrent(request, for: key) {
                    setStatus(.succeeded, for: key)
                    return
                }
                // A newer value was enqueued while this call was in flight.
                // Process it next instead of discarding it.
                attempt = 0
                setStatus(.pending, for: key)
            } catch {
                attempt += 1
                guard retryPolicy.isRetryable(error), attempt <= retryPolicy.maxAttempts else {
                    if await store.removeIfCurrent(request, for: key) {
                        setStatus(.failed(MutationFailureReason(error)), for: key)
                        return
                    }
                    // A newer value replaced this one while it was failing
                    // permanently; that replacement deserves its own attempts
                    // rather than being discarded alongside the old failure.
                    attempt = 0
                    setStatus(.pending, for: key)
                    continue
                }
                setStatus(.retrying(attempt: attempt), for: key)
                let delay = retryPolicy.delay(forAttempt: attempt)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    // MARK: - Status Broadcasting

    private func setStatus(_ status: MutationStatus, for key: MutationKey) {
        latestStatusByKey[key] = status
        let event = MutationEvent(key: key, status: status)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
