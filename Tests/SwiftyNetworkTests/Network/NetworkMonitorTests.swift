import Testing

@testable import SwiftyNetwork

@Test("NetworkMonitor starts with unreachable status")
func testNetworkMonitorInitialReachability() async {
    let monitor = NetworkMonitor()
    let reachable = await monitor.isReachable
    #expect(reachable == false)
}

@Test("NetworkMonitor can restart after stopping")
func testNetworkMonitorCanRestartAfterStopping() async {
    let monitor = NetworkMonitor()

    await monitor.startMonitoring()
    await monitor.stopMonitoring()
    await monitor.startMonitoring()
    await monitor.stopMonitoring()
}
