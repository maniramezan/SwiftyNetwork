import SwiftyNetwork
import TestCommons
import Testing

struct FakeAPIClientTests {
    @Test("An earlier held call keeps its scripted failure when a later call finishes first")
    func heldCallsKeepArrivalOrder() async throws {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout), .success])
        let gate = await fake.hold(call: 0)
        defer { gate.open() }

        async let first: Result<EmptyResponse, any Error> = result(of: fake)
        _ = try await waitUntil(
            timeout: .seconds(2), operation: { await fake.callCount }, matching: { $0 == 1 })
        let second = try await fake.request(TestEndpoint(), responseType: EmptyResponse.self)
        #expect(second == EmptyResponse())
        gate.open()

        let firstResult = await first
        switch firstResult {
        case .success:
            Issue.record("Expected the first call's scripted failure")
        case .failure(let error):
            #expect((error as? NetworkError)?.classification == .timeout)
        }
        #expect(await fake.callCount == 2)
    }

    private func result(of fake: FakeAPIClient) async -> Result<EmptyResponse, any Error> {
        do {
            return .success(try await fake.request(TestEndpoint(), responseType: EmptyResponse.self))
        } catch {
            return .failure(error)
        }
    }
}
