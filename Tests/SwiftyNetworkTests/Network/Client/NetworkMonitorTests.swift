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

@Test("NetworkMonitor status reports unknown before monitoring starts")
func testNetworkMonitorStatusBeforeMonitoring() async {
    let monitor = NetworkMonitor()
    #expect(await monitor.status == .unknown)
}

@Test("NetworkMonitor updates stream emits current status immediately")
func testNetworkMonitorUpdatesEmitsCurrentStatus() async {
    let monitor = NetworkMonitor()
    let stream = await monitor.updates

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()

    #expect(first == .unknown)
}

@Test("NetworkMonitor supports multiple independent update streams")
func testNetworkMonitorMultipleIndependentStreams() async {
    let monitor = NetworkMonitor()
    let streamA = await monitor.updates
    let streamB = await monitor.updates

    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()

    #expect(await iteratorA.next() == .unknown)
    #expect(await iteratorB.next() == .unknown)
}

@Test("NetworkMonitor finishes update streams when monitoring stops")
func testNetworkMonitorStopFinishesStreams() async {
    let monitor = NetworkMonitor()
    let stream = await monitor.updates
    var iterator = stream.makeAsyncIterator()

    _ = await iterator.next()
    await monitor.startMonitoring()
    await monitor.stopMonitoring()

    var drained = 0
    while await iterator.next() != nil {
        drained += 1
        if drained > 10 { break }
    }

    let next = await iterator.next()
    #expect(next == nil)
}
