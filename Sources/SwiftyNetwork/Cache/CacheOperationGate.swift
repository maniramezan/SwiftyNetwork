/// Serializes compound storage operations across suspension points, one key at a time.
///
/// Operations for the same key run in arrival order. Operations for different keys run
/// concurrently, so slow storage for one key does not delay another. An exclusive operation,
/// such as clearing everything, waits for every running operation and holds back all later
/// ones until it finishes.
///
/// Admission is first-in, first-out among operations that conflict: an operation never
/// overtakes an earlier one for the same key, or an earlier exclusive one.
///
/// Callers must not recursively enter the gate for the same key, or enter it at all from
/// inside an exclusive operation. Cancellation does not skip queued storage mutations: an
/// invalidation must complete before it returns. Network fetches must run outside the gate
/// so invalidation can cancel them.
actor CacheOperationGate<Key: Hashable & Sendable> {
    private enum Scope {
        case key(Key)
        case all
    }

    private struct Waiter {
        let scope: Scope
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeKeys: Set<Key> = []
    private var isExclusiveActive = false
    private var waiters: [Waiter] = []

    /// Internal diagnostic used to observe queue admission in concurrency tests.
    var queuedOperationCount: Int { waiters.count }

    /// Runs `operation` after every earlier operation for `key`, and every earlier
    /// exclusive operation, has finished.
    func run<Result: Sendable>(
        for key: Key,
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire(.key(key))
        defer { release(.key(key)) }
        return try await operation()
    }

    /// Runs `operation` alone: after every earlier operation has finished, and before any later one starts.
    func runExclusive<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire(.all)
        defer { release(.all) }
        return try await operation()
    }

    private func acquire(_ scope: Scope) async {
        if !conflictsWithActive(scope), !conflictsWithQueued(scope) {
            activate(scope)
            return
        }
        // `release` activates the scope before resuming the continuation.
        await withCheckedContinuation { waiters.append(Waiter(scope: scope, continuation: $0)) }
    }

    private func release(_ scope: Scope) {
        switch scope {
        case .key(let key): activeKeys.remove(key)
        case .all: isExclusiveActive = false
        }

        // Admit waiters in arrival order. One that stays queued blocks later waiters it conflicts with.
        var stillWaiting: [Waiter] = []
        var blockedKeys: Set<Key> = []
        var isExclusiveWaiting = false
        for waiter in waiters {
            let isBlockedByEarlierWaiter: Bool
            switch waiter.scope {
            case .key(let key): isBlockedByEarlierWaiter = isExclusiveWaiting || blockedKeys.contains(key)
            case .all: isBlockedByEarlierWaiter = isExclusiveWaiting || !blockedKeys.isEmpty
            }
            if isBlockedByEarlierWaiter || conflictsWithActive(waiter.scope) {
                stillWaiting.append(waiter)
                switch waiter.scope {
                case .key(let key): blockedKeys.insert(key)
                case .all: isExclusiveWaiting = true
                }
            } else {
                activate(waiter.scope)
                waiter.continuation.resume()
            }
        }
        waiters = stillWaiting
    }

    private func activate(_ scope: Scope) {
        switch scope {
        case .key(let key): activeKeys.insert(key)
        case .all: isExclusiveActive = true
        }
    }

    private func conflictsWithActive(_ scope: Scope) -> Bool {
        switch scope {
        case .key(let key): isExclusiveActive || activeKeys.contains(key)
        case .all: isExclusiveActive || !activeKeys.isEmpty
        }
    }

    private func conflictsWithQueued(_ scope: Scope) -> Bool {
        switch scope {
        case .all:
            return !waiters.isEmpty
        case .key(let key):
            return waiters.contains { waiter in
                switch waiter.scope {
                case .all: true
                case .key(let queued): queued == key
                }
            }
        }
    }
}
