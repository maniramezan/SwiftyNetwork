import Testing

@testable import SwiftyNetwork

@Test("NetworkMonitor starts with unreachable status")
func testNetworkMonitorInitialReachability() async {
    let monitor = NetworkMonitor()
    let reachable = await monitor.isReachable
    #expect(reachable == false)
}
