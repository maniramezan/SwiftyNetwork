import Foundation
import Network

/// An actor that monitors network path changes to provide reachability status.
public actor NetworkMonitor {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private var status = NWPath.Status.requiresConnection
    private var isMonitoring = false

    public init() {
        self.monitor = NWPathMonitor()
    }

    /// Starts monitoring network path updates. Call with `await NetworkMonitor.shared.startMonitoring()`.
    public func startMonitoring() {
        guard !isMonitoring else { return }

        monitor.pathUpdateHandler = { path in
            Task {
                await NetworkMonitor.shared.setStatus(path.status)
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitorQueue")
        monitor.start(queue: queue)
        isMonitoring = true
    }

    /// Stops monitoring network path updates.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        monitor.cancel()
        isMonitoring = false
    }

    private func setStatus(_ newStatus: NWPath.Status) {
        status = newStatus
    }

    /// A boolean indicating whether the network is currently reachable.
    public var isReachable: Bool {
        status == .satisfied
    }
}
