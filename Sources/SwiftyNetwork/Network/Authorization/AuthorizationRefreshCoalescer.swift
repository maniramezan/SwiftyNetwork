import Foundation

/// Thrown when a refresh is requested from inside that same refresh.
///
/// This happens when a refresh operation sends its request through a client whose provider
/// refreshes through the same ``AuthorizationRefreshCoalescer``, and that request gets a `401`.
/// Waiting for the refresh in progress would wait for itself forever, so the nested call fails
/// instead, and ``NetworkClient`` surfaces it as ``NetworkError/authorizationRefreshFailed(underlying:)``.
/// To avoid it, give the refresh endpoint ``NetworkEndpoint/usesAuthorizationProvider`` `false`.
public struct ReentrantRefreshError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A description of the error.
    public var description: String {
        "A refresh was requested from inside the same refresh"
    }

    /// Creates the error.
    public init() {}
}

/// Runs at most one authorization refresh at a time and shares it with every concurrent caller.
///
/// Store one in a custom ``AuthorizationProvider`` and route
/// ``AuthorizationProvider/refreshAuthorization(rejecting:)`` through it. When several requests
/// fail with the same expired credential, the first starts the refresh, the rest join it, and a
/// `401` that arrives after the credential was already replaced returns without refreshing. This
/// matters for servers that rotate refresh tokens, where a second refresh with a consumed refresh
/// token fails and signs the user out. ``OAuthAuthorizationProvider`` is built on this type.
///
/// ```swift
/// actor SessionAuthProvider: AuthorizationProvider {
///     private let refreshes = AuthorizationRefreshCoalescer()
///     private var sessionToken: String
///
///     init(sessionToken: String) {
///         self.sessionToken = sessionToken
///     }
///
///     func currentAuthorization() async -> AuthorizationType {
///         .custom(header: "X-Session", value: sessionToken)
///     }
///
///     func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
///         try await refreshes.refresh(rejecting: rejected, of: self) {
///             let token = try await sessionService.reauthenticate()
///             await self.store(token)
///         }
///     }
///
///     /// An app-initiated refresh that always reflects state as of this call.
///     func forceRefresh() async throws {
///         try await refreshes.refresh {
///             let token = try await sessionService.reauthenticate()
///             await self.store(token)
///         }
///     }
///
///     private func store(_ token: String) {
///         sessionToken = token
///     }
/// }
/// ```
///
/// The refresh operation must store the new credential before it returns, so that callers
/// arriving afterward see that the rejected credential is no longer current.
///
/// Only the operation passed by the caller that starts a refresh runs; callers that join it
/// share its result, and their operations are discarded. A forced ``refresh(_:)`` never joins a
/// refresh that started before it was called, because that refresh may have requested
/// credentials before the change the app is reacting to. Every joiner receives the same error
/// when the refresh fails. A failure is not remembered, so the next call refreshes again.
///
/// A canceled caller does not cancel the shared refresh; it receives the refresh's result when it
/// finishes. A call made from inside the running refresh throws ``ReentrantRefreshError``.
public actor AuthorizationRefreshCoalescer {
    /// Coalescers whose refresh operation is running in the current task, to detect a nested refresh.
    @TaskLocal private static var activeCoalescers: Set<ObjectIdentifier> = []

    private struct Flight: Sendable {
        /// Increases with every started flight, so a caller can tell whether a flight started after it.
        let sequence: Int
        let task: Task<Void, any Error>
    }

    private var inFlight: Flight?
    private var startedFlights = 0
    private var completedFlights = 0
    /// How many calls have waited on a refresh started by another caller, so tests can wait for them.
    private(set) var joinedCallers = 0

    /// Creates a coalescer with no refresh in flight.
    public init() {}

    /// Refreshes after `rejected` was refused, unless a newer usable authorization exists or a refresh is running.
    ///
    /// - If `isCurrentAuthorization` returns `false`, a newer usable authorization exists, so this
    ///   returns without running `refresh` and the client retries with that authorization.
    /// - If a refresh is in flight, this waits for it and returns its result.
    /// - Otherwise, this runs `refresh` and shares it with every caller that arrives meanwhile.
    ///
    /// Use this overload when equality is not enough to decide whether authorization was replaced.
    /// For example, if a provider represents no usable token as ``AuthorizationType/none``, a
    /// rejection of a bearer token must still return `true` until a usable replacement exists.
    ///
    /// - Parameters:
    ///   - rejected: The authorization the server rejected, as passed to
    ///     ``AuthorizationProvider/refreshAuthorization(rejecting:)``.
    ///   - isCurrentAuthorization: Returns `true` when `rejected` still needs a refresh, or
    ///     `false` when a usable replacement is available.
    ///   - refresh: Obtains and stores a new credential, or throws when it cannot.
    /// - Throws: The shared refresh's error, `CancellationError` when the shared refresh was
    ///   canceled, or ``ReentrantRefreshError`` when called from inside the running refresh.
    public func refresh(
        rejecting rejected: AuthorizationType,
        isCurrentAuthorization: @escaping @Sendable () async -> Bool,
        _ refresh: @escaping @Sendable () async throws -> Void
    ) async throws {
        try checkReentrancy()
        while true {
            let observedFlights = completedFlights
            guard await isCurrentAuthorization() else {
                Logger.debug("Rejected authorization was already replaced; skipping refresh", category: .auth)
                return
            }
            if let flight = inFlight {
                try await join(flight)
                return
            }
            // A whole refresh finished while the staleness check was suspended, so check again.
            if completedFlights == observedFlights { break }
        }
        try await start(refresh)
    }

    /// Refreshes after `rejected` was refused, unless the provider has already replaced it.
    ///
    /// This convenience overload compares `rejected` with
    /// ``AuthorizationProvider/isCurrentAuthorization(_:)``: a thrown error means refresh is
    /// needed, while any different value is treated as a usable replacement. Use
    /// ``refresh(rejecting:isCurrentAuthorization:_:)`` instead when a different authorization
    /// value can still mean that no usable replacement exists, such as a provider that reports no
    /// token as ``AuthorizationType/none``. Alternatively, pass a probe provider whose
    /// `currentAuthorization()` throws for the no-credential value; it need not change the
    /// authorization provider used for requests.
    ///
    /// ```swift
    /// struct RefreshProbe: AuthorizationProvider {
    ///     struct NoCredential: Error {}
    ///     let provider: any AuthorizationProvider
    ///
    ///     func currentAuthorization() async throws -> AuthorizationType {
    ///         let current = try await provider.currentAuthorization()
    ///         guard current != .none else { throw NoCredential() }
    ///         return current
    ///     }
    ///
    ///     func refreshAuthorization(rejecting: AuthorizationType) async throws {}
    /// }
    ///
    /// // In the real provider's refreshAuthorization(rejecting:):
    /// try await refreshes.refresh(rejecting: rejected, of: RefreshProbe(provider: self)) {
    ///     try await self.obtainAndStoreCredential()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - rejected: The authorization the server rejected, as passed to
    ///     ``AuthorizationProvider/refreshAuthorization(rejecting:)``.
    ///   - provider: The provider whose current authorization is compared against `rejected`.
    ///   - refresh: Obtains and stores a new credential, or throws when it cannot.
    /// - Throws: The shared refresh's error, `CancellationError` when the shared refresh is
    ///   canceled, or ``ReentrantRefreshError`` when called from inside the running refresh.
    public func refresh(
        rejecting rejected: AuthorizationType,
        of provider: some AuthorizationProvider,
        _ refresh: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await self.refresh(
            rejecting: rejected,
            isCurrentAuthorization: { await provider.isCurrentAuthorization(rejected) },
            refresh
        )
    }

    /// Refreshes unconditionally, with a refresh that starts after this call.
    ///
    /// Use it for refreshes the app starts itself, for example after the user changes plans, so
    /// the new credential reflects the change. A refresh already in flight may have requested its
    /// credential before the change, so this waits for it to finish, ignores its result, and then
    /// runs another. Every forced call that arrives while the same refresh is running shares that
    /// one next refresh. A ``refresh(rejecting:of:_:)`` call joins whichever refresh is running.
    ///
    /// - Parameter refresh: Obtains and stores a new credential, or throws when it cannot.
    /// - Throws: The error of the refresh that started after this call, `CancellationError` when
    ///   that refresh was canceled, or ``ReentrantRefreshError`` when called from inside the
    ///   running refresh.
    public func refresh(_ refresh: @escaping @Sendable () async throws -> Void) async throws {
        try checkReentrancy()
        let lastStartedBeforeCall = startedFlights
        while let flight = inFlight {
            if flight.sequence > lastStartedBeforeCall {
                try await join(flight)
                return
            }
            Logger.debug("Waiting for an older authorization refresh before forcing a new one", category: .auth)
            joinedCallers += 1
            _ = await flight.task.result
        }
        try await start(refresh)
    }

    // MARK: - Private

    private func checkReentrancy() throws {
        guard Self.activeCoalescers.contains(ObjectIdentifier(self)) else { return }
        Logger.error(
            "Refresh requested from inside the running refresh; failing it instead of waiting on itself",
            category: .auth
        )
        throw ReentrantRefreshError()
    }

    private func join(_ flight: Flight) async throws {
        Logger.debug("Joining the authorization refresh in flight", category: .auth)
        joinedCallers += 1
        try await flight.task.value
    }

    private func start(_ refresh: @escaping @Sendable () async throws -> Void) async throws {
        startedFlights += 1
        let sequence = startedFlights
        let active = Self.activeCoalescers.union([ObjectIdentifier(self)])
        Logger.debug("Starting an authorization refresh", category: .auth)
        let task = Task<Void, any Error> {
            do {
                try await Self.$activeCoalescers.withValue(active) {
                    try await refresh()
                }
            } catch {
                finish(sequence, error: error)
                throw error
            }
            finish(sequence, error: nil)
        }
        inFlight = Flight(sequence: sequence, task: task)
        try await task.value
    }

    private func finish(_ sequence: Int, error: (any Error)?) {
        if let error, !(error is CancellationError) {
            Logger.error("Authorization refresh failed", error: error, category: .auth)
        }
        guard inFlight?.sequence == sequence else { return }
        inFlight = nil
        completedFlights += 1
    }
}
