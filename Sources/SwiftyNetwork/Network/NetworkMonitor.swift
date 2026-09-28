import Foundation
import Network
import SwiftCommons

/// Reachability status reported by ``NetworkMonitor``.
public enum NetworkReachability: Sendable, Equatable {
    /// The network is reachable.
    case reachable
    /// The network is not currently reachable.
    case unreachable
    /// Reachability is unknown (e.g. monitoring has not started yet).
    case unknown

    /// Maps an ``NWPath/Status`` value to a reachability case.
    init(_ status: NWPath.Status) {
        switch status {
        case .satisfied: self = .reachable
        case .unsatisfied: self = .unreachable
        case .requiresConnection: self = .unreachable
        @unknown default: self = .unknown
        }
    }
}

/// An actor that monitors network path changes and exposes them via async APIs.
///
/// Until ``startMonitoring()`` is called, ``isReachable`` reports `false` and
/// ``status`` reports ``NetworkReachability/unknown``. Use ``updates`` to
/// observe a continuous stream of reachability changes.
///
/// Example:
/// ```swift
/// let monitor = NetworkMonitor.shared
/// await monitor.startMonitoring()
///
/// for await status in await monitor.updates {
///     print("Network status: \(status)")
/// }
/// ```
public actor NetworkMonitor {
    /// Shared singleton instance for global network monitoring.
    public static let shared = NetworkMonitor()

    private var monitor: NWPathMonitor?
    private var pathUpdates: AsyncStream<NetworkReachability>.Continuation?
    private var pathUpdatesTask: Task<Void, Never>?
    private var currentStatus: NetworkReachability = .unknown
    private var broadcaster = AsyncBroadcaster<NetworkReachability>(
        initialValue: .unknown, bufferingPolicy: .bufferingNewest(1)
    )

    /// Creates a new network monitor. Use ``shared`` unless multiple independent
    /// monitors are needed.
    public init() {
    }

    /// Begins observing network path changes.
    ///
    /// Subsequent calls are no-ops while monitoring is active. Path changes are
    /// applied in the order the system reports them.
    ///
    /// Example:
    /// ```swift
    /// await NetworkMonitor.shared.startMonitoring()
    /// let reachable = await NetworkMonitor.shared.isReachable
    /// ```
    public func startMonitoring() {
        guard monitor == nil else { return }

        // A single stream + consumer task keeps updates ordered; spawning a
        // task per callback would let a stale status overwrite a newer one.
        let (statuses, continuation) = AsyncStream.makeStream(of: NetworkReachability.self)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable path in
            continuation.yield(NetworkReachability(path.status))
        }
        pathUpdatesTask = Task { [weak self] in
            for await status in statuses {
                guard let self else { return }
                await self.update(status)
            }
        }
        monitor.start(queue: DispatchQueue(label: "SwiftyNetwork.NetworkMonitorQueue"))
        self.monitor = monitor
        pathUpdates = continuation
    }

    /// Stops observing network path changes and finishes any active update streams.
    ///
    /// Example:
    /// ```swift
    /// await NetworkMonitor.shared.stopMonitoring()
    /// ```
    public func stopMonitoring() {
        guard let monitor else { return }
        monitor.cancel()
        self.monitor = nil
        pathUpdates?.finish()
        pathUpdates = nil
        pathUpdatesTask?.cancel()
        pathUpdatesTask = nil
        broadcaster.finish()
        broadcaster = AsyncBroadcaster(initialValue: currentStatus, bufferingPolicy: .bufferingNewest(1))
    }

    /// The most recently reported reachability status.
    ///
    /// Before monitoring starts, this is ``NetworkReachability/unknown``.
    public var status: NetworkReachability {
        currentStatus
    }

    /// `true` if the network is currently reachable.
    ///
    /// This is a convenience wrapper around ``status`` equal to
    /// ``NetworkReachability/reachable``.
    public var isReachable: Bool {
        currentStatus == .reachable
    }

    /// An async stream of reachability updates.
    ///
    /// Call this once per consumer; each call returns an independent stream
    /// that starts with the current status. A slow consumer only sees the most
    /// recent status rather than a backlog of stale ones.
    /// The stream finishes when ``stopMonitoring()`` is called or when the
    /// consumer cancels iteration. A stream created while monitoring is stopped
    /// stays idle and resumes delivering values once monitoring starts again.
    ///
    /// Example:
    /// ```swift
    /// let stream = await NetworkMonitor.shared.updates
    /// for await status in stream {
    ///     print(status)
    /// }
    /// ```
    public var updates: AsyncStream<NetworkReachability> {
        broadcaster.makeStream()
    }

    // MARK: - Private

    private func update(_ newStatus: NetworkReachability) {
        guard newStatus != currentStatus else { return }
        currentStatus = newStatus
        Logger.info("Network reachability changed to \(newStatus)", category: .network)
        broadcaster.yield(newStatus)
    }
}
