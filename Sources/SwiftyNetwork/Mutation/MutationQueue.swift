import Foundation
internal import SwiftCommons

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
/// `MutationQueue` only reports outcomes via ``events()`` / ``status(for:)``, or to a caller
/// that waits with ``enqueueAndWait(_:key:)`` -- it does not manage UI state. Optimistic updates and rollback on
/// permanent failure remain the caller's responsibility.
///
/// Mutations for different keys run independently and may finish in any order.
/// Enqueue a dependent mutation (for example, a child of a record still being
/// created) only after the event for the first one reports ``MutationStatus/succeeded``.
///
/// The queue replays `POST` and `PATCH` requests after a timeout or a `5xx`, when the
/// server may already have applied them. If your API supports idempotency keys, send
/// one with ``MutationRequest/addingIdempotencyKey(_:header:)`` so a replay can't apply
/// the mutation twice.
///
/// By default, pending mutations live in memory and an offline failure counts as a retry
/// like any other, so a mutation is dropped after ``MutationRetryPolicy/maxRetries`` attempts
/// or when the app is terminated. To keep them, use the durable ``FileMutationStore`` and pass
/// `waitForConnectivity` so offline mutations wait for the network instead:
///
/// ```swift
/// let queue = MutationQueue(client: client, store: FileMutationStore(directory: directory)) {
///     await NetworkMonitor.shared.waitUntilReachable()
/// }
/// await queue.resumePendingMutations()
/// ```
///
/// Example:
/// ```swift
/// let queue = MutationQueue(client: authenticatedClient)
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
        /// The logical mutation whose status changed.
        public let key: MutationKey
        /// The new status for ``key``.
        public let status: MutationStatus
        /// The server's response for a ``MutationStatus/succeeded`` event, including its body,
        /// for example the identifier the server assigned to a created record. `nil` for every
        /// other status.
        ///
        /// Example:
        /// ```swift
        /// if event.status == .succeeded, let created = try? event.response?.decodeBody(Post.self) {
        ///     store.replaceDraft(id: event.key, with: created)
        /// }
        /// ```
        public let response: HTTPResponse?

        /// Creates an event, for example to drive UI previews or test doubles.
        ///
        /// - Parameters:
        ///   - key: The logical mutation whose status changed.
        ///   - status: The new status.
        ///   - response: The server's response, for a ``MutationStatus/succeeded`` event.
        public init(key: MutationKey, status: MutationStatus, response: HTTPResponse? = nil) {
            self.key = key
            self.status = status
            self.response = response
        }
    }

    private let client: any APIClient
    private let store: any MutationStore
    private let retryPolicy: MutationRetryPolicy
    private let waitForConnectivity: (@Sendable () async -> Void)?

    /// A background task processing one key. The `id` lets a worker detect
    /// that it was cancelled and replaced, so it never touches the store or
    /// publishes status on behalf of a newer worker.
    private struct Worker {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum FinishResult: Sendable {
        case completed
        case superseded
        case noLongerCurrent
    }

    /// How many finished mutations ``status(for:)`` remembers. Older ones are forgotten, so a
    /// queue that sees an unbounded number of keys does not grow without limit.
    static let retainedFinishedStatusLimit = 500

    /// The status of every mutation that is still pending, retrying, or waiting.
    private var activeStatusByKey: [MutationKey: MutationStatus] = [:]
    /// The outcome of the most recently finished mutations, oldest first.
    private var finishedStatusByKey = LRUStorage<MutationKey, MutationStatus>()
    private var workerByKey: [MutationKey: Worker] = [:]
    /// Serializes enqueue and cancel per key, and resume and cancel-all against everything,
    /// across storage suspension points.
    /// Internal visibility lets regression tests observe gate admission.
    let operations = CacheOperationGate<MutationKey>()
    private let eventBroadcaster = AsyncBroadcaster<MutationEvent>()

    /// Creates a mutation queue.
    ///
    /// - Parameters:
    ///   - client: The client used to execute mutations. Configure its
    ///     ``NetworkClientConfiguration/authorizationProvider``: mutations carry no
    ///     credentials of their own (see ``MutationRequest``).
    ///   - store: Where pending mutations are persisted. Defaults to a fresh ``InMemoryMutationStore``.
    ///   - retryPolicy: Governs retry attempts and backoff. Defaults to ``MutationRetryPolicy/default``.
    ///   - waitForConnectivity: Returns once the network is reachable again, typically
    ///     ``NetworkMonitor/waitUntilReachable()``. When set, an attempt that fails with
    ///     ``NetworkError/noInternetConnection`` does not use up a retry: the mutation reports
    ///     ``MutationStatus/waitingForConnectivity``, stays in the store, and is retried after this
    ///     returns and the first backoff delay passes. It must also return when the calling task is
    ///     cancelled. When `nil`, the default, offline failures count as retries.
    public init(
        client: any APIClient,
        store: any MutationStore = InMemoryMutationStore(),
        retryPolicy: MutationRetryPolicy = .default,
        waitForConnectivity: (@Sendable () async -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.retryPolicy = retryPolicy
        self.waitForConnectivity = waitForConnectivity
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
        await operations.run(for: key) { await self.performEnqueue(request, key: key) }
    }

    /// Enqueues a mutation and waits for the outcome of its key.
    ///
    /// Use it when the caller needs the result, for example to roll back an optimistic update,
    /// but should still get the queue's retries, coalescing, and persistence. It replaces
    /// subscribing to ``events()`` before calling ``enqueue(_:key:)``.
    ///
    /// The outcome is that of the key, not of this request alone: if a newer mutation for the
    /// same key replaces this one, the call returns or throws with the replacement's outcome,
    /// which is the state the server ends up in.
    ///
    /// Cancelling the calling task stops the wait with `CancellationError`, but the mutation
    /// stays in the queue. Use ``cancel(_:)`` to cancel the mutation itself.
    ///
    /// Example:
    /// ```swift
    /// do {
    ///     try await queue.enqueueAndWait(MutationRequest(endpoint: LikeEndpoint(id: 42)), key: "like:42")
    /// } catch let reason as MutationFailureReason where !reason.isCancellation {
    ///     rollBackOptimisticLike()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - request: The mutation to execute.
    ///   - key: The logical mutation this belongs to, for coalescing.
    /// - Returns: The server's response to the mutation that settled the key.
    /// - Throws: ``MutationFailureReason`` when the mutation failed permanently or was cancelled
    ///   with ``cancel(_:)`` or ``cancelAll()``; `CancellationError` when the calling task was cancelled.
    @discardableResult
    public func enqueueAndWait(_ request: MutationRequest, key: MutationKey) async throws -> HTTPResponse {
        // Subscribe first, so the outcome can't be published before the loop starts.
        let events = eventBroadcaster.makeStream()
        await enqueue(request, key: key)
        // Events before this enqueue's own `.pending` belong to an earlier mutation for the key.
        var isEnqueued = false
        for await event in events where event.key == key {
            switch event.status {
            case .pending:
                isEnqueued = true
            case .retrying, .waitingForConnectivity:
                continue
            case .succeeded:
                guard isEnqueued else { continue }
                guard let response = event.response else {
                    throw NetworkError.invalidResponse
                }
                return response
            case .failed(let reason):
                guard isEnqueued else { continue }
                throw reason
            }
        }
        throw CancellationError()
    }

    private func performEnqueue(_ request: MutationRequest, key: MutationKey) async {
        Logger.debug("Enqueuing mutation for key \(key)", category: .mutation)
        await store.save(request, for: key)
        setStatus(.pending, for: key)
        startProcessingIfNeeded(for: key)
    }

    /// Cancels the pending mutation for `key` and removes it from the store.
    ///
    /// Use this when the desired state no longer matters (for example, the
    /// user deleted the item). If a mutation is pending or retrying, it
    /// finishes with ``MutationStatus/failed(_:)`` and a reason whose
    /// ``MutationFailureReason/isCancellation`` is `true`. A request already
    /// on the wire can't be recalled: the server may still apply it, but its
    /// result is ignored. Does nothing if `key` has no pending mutation.
    ///
    /// - Parameter key: The logical mutation to cancel.
    public func cancel(_ key: MutationKey) async {
        await operations.run(for: key) { await self.performCancel(key) }
    }

    /// Cancels every pending mutation and clears the store.
    ///
    /// Call this on sign-out. Persisted mutations can carry credentials and
    /// must not be replayed for the next user.
    public func cancelAll() async {
        await operations.runExclusive {
            var keys = Set(await self.store.allKeys())
            keys.formUnion(await self.activeKeys())
            for key in keys {
                await self.performCancel(key)
            }
        }
    }

    private func activeKeys() -> [MutationKey] {
        Array(workerByKey.keys)
    }

    private func performCancel(_ key: MutationKey) async {
        let worker = workerByKey.removeValue(forKey: key)
        worker?.task.cancel()
        let hadStoredRequest = await store.load(for: key) != nil
        await store.remove(for: key)
        guard worker != nil || hadStoredRequest else { return }
        Logger.debug("Cancelled mutation for key \(key)", category: .mutation)
        setStatus(.failed(MutationFailureReason(CancellationError())), for: key)
    }

    /// The most recently observed status for `key`.
    ///
    /// A mutation that is still in progress always has a status. The outcome of a finished
    /// mutation, ``MutationStatus/succeeded`` or ``MutationStatus/failed(_:)``, is remembered
    /// for the most recent few hundred keys.
    ///
    /// - Parameter key: The logical mutation to look up.
    /// - Returns: The status, or `nil` when `key` was never enqueued or its outcome was forgotten.
    public func status(for key: MutationKey) -> MutationStatus? {
        activeStatusByKey[key] ?? finishedStatusByKey.peekValue(forKey: key)
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
        await operations.runExclusive { await self.performResumePendingMutations() }
    }

    private func performResumePendingMutations() async {
        let keys = await store.allKeys()
        Logger.info("Resuming \(keys.count) pending mutation(s) from the store", category: .mutation)
        for key in keys {
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
        eventBroadcaster.makeStream()
    }

    // MARK: - Processing

    private func startProcessingIfNeeded(for key: MutationKey) {
        guard workerByKey[key] == nil else { return }
        let id = UUID()
        // The task can't start running `process` until this actor-isolated
        // method returns, so the worker is registered before it runs.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.process(key: key, workerID: id)
        }
        workerByKey[key] = Worker(id: id, task: task)
    }

    private func isCurrentWorker(_ id: UUID, for key: MutationKey) -> Bool {
        workerByKey[key]?.id == id && !Task.isCancelled
    }

    private func process(key: MutationKey, workerID: UUID) async {
        defer {
            if workerByKey[key]?.id == workerID {
                workerByKey[key] = nil
            }
        }

        var attempt = 0
        var attemptedRequest: MutationRequest?
        while isCurrentWorker(workerID, for: key) {
            guard let request = await store.load(for: key), isCurrentWorker(workerID, for: key) else { return }
            if request != attemptedRequest {
                attempt = 0
                attemptedRequest = request
            }

            Logger.debug("Executing mutation for key \(key) (attempt \(attempt + 1))", category: .mutation)
            do {
                let result = try await client.response(for: request, responseType: EmptyResponse.self)
                // Cancelled while on the wire: the queue already reported the
                // cancellation, so ignore this outcome entirely.
                guard isCurrentWorker(workerID, for: key) else { return }

                switch await finish(
                    request, for: key, workerID: workerID, status: .succeeded, response: result.response)
                {
                case .completed:
                    Logger.debug("Mutation succeeded for key \(key)", category: .mutation)
                    return
                case .superseded:
                    Logger.debug(
                        "Mutation for key \(key) was superseded while in flight; processing replacement",
                        category: .mutation
                    )
                    attempt = 0
                case .noLongerCurrent:
                    return
                }
            } catch {
                guard isCurrentWorker(workerID, for: key) else { return }
                if let waitForConnectivity, (error as? NetworkError)?.category == .offline {
                    Logger.info("Mutation for key \(key) is waiting for connectivity", category: .mutation)
                    setStatus(.waitingForConnectivity, for: key)
                    await waitForConnectivity()
                    guard isCurrentWorker(workerID, for: key) else { return }
                    Logger.debug("Connectivity is back; retrying mutation for key \(key)", category: .mutation)
                    // Networks flap right after reconnecting, so wait the first backoff delay.
                    // This also keeps a closure that returns immediately from spinning.
                    let delay = retryPolicy.delay(forRetry: 1)
                    if delay > .zero {
                        try? await Task.sleep(for: delay)
                    }
                    guard isCurrentWorker(workerID, for: key) else { return }
                    setStatus(.pending, for: key)
                    continue
                }
                attempt += 1
                guard retryPolicy.shouldRetry(error), attempt <= retryPolicy.maxRetries else {
                    switch await finish(
                        request, for: key, workerID: workerID, status: .failed(MutationFailureReason(error)))
                    {
                    case .completed:
                        Logger.error("Mutation failed permanently for key \(key)", error: error, category: .mutation)
                        return
                    case .noLongerCurrent:
                        return
                    case .superseded:
                        // A newer value replaced this one while it was failing
                        // permanently; that replacement deserves its own attempts.
                        Logger.debug(
                            "Mutation for key \(key) was superseded during a permanent failure; processing replacement",
                            category: .mutation
                        )
                        attempt = 0
                    }
                    continue
                }
                Logger.warning(
                    "Mutation for key \(key) failed transiently (attempt \(attempt)); retrying",
                    category: .mutation
                )
                setStatus(.retrying(attempt: attempt), for: key)
                let delay = retryPolicy.delay(forRetry: attempt, after: error)
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
            }
        }
    }

    /// Serializes terminal cleanup with enqueue so a replacement cannot be saved after the
    /// current value is removed but before its worker is cleared.
    private func finish(
        _ request: MutationRequest,
        for key: MutationKey,
        workerID: UUID,
        status: MutationStatus,
        response: HTTPResponse? = nil
    ) async -> FinishResult {
        await operations.run(for: key) {
            guard await self.isCurrentWorker(workerID, for: key) else { return .noLongerCurrent }
            let removed = await self.store.removeIfCurrent(request, for: key)
            guard await self.isCurrentWorker(workerID, for: key) else { return .noLongerCurrent }
            guard removed else {
                await self.setStatus(.pending, for: key)
                return .superseded
            }
            await self.setStatus(status, for: key, response: response)
            await self.clearWorker(workerID, for: key)
            return .completed
        }
    }

    private func clearWorker(_ workerID: UUID, for key: MutationKey) {
        if workerByKey[key]?.id == workerID {
            workerByKey[key] = nil
        }
    }

    // MARK: - Status Broadcasting

    private func setStatus(_ status: MutationStatus, for key: MutationKey, response: HTTPResponse? = nil) {
        switch status {
        case .pending, .retrying, .waitingForConnectivity:
            finishedStatusByKey.removeValue(forKey: key)
            activeStatusByKey[key] = status
        case .succeeded, .failed:
            activeStatusByKey[key] = nil
            finishedStatusByKey.setValue(status, forKey: key)
            while finishedStatusByKey.count > Self.retainedFinishedStatusLimit {
                finishedStatusByKey.removeLeastRecentlyUsed()
            }
        }
        eventBroadcaster.yield(MutationEvent(key: key, status: status, response: response))
    }
}
