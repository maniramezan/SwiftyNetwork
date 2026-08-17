import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("InMemoryMutationStore Tests")
struct InMemoryMutationStoreTests {

    @Test("Save then load returns the saved request")
    func saveThenLoad() async {
        let store = InMemoryMutationStore()
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/x", method: .post)

        await store.save(request, for: "key")

        #expect(await store.load(for: "key") == request)
    }

    @Test("Load returns nil for a key that was never saved")
    func loadMissingKeyReturnsNil() async {
        let store = InMemoryMutationStore()

        #expect(await store.load(for: "missing") == nil)
    }

    @Test("Saving again for the same key overwrites the previous value")
    func saveOverwrites() async {
        let store = InMemoryMutationStore()
        let first = MutationRequest(baseURL: "https://api.test.com", path: "/first", method: .post)
        let second = MutationRequest(baseURL: "https://api.test.com", path: "/second", method: .post)

        await store.save(first, for: "key")
        await store.save(second, for: "key")

        #expect(await store.load(for: "key") == second)
    }

    @Test("Remove clears the stored request")
    func removeClearsRequest() async {
        let store = InMemoryMutationStore()
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/x", method: .post)
        await store.save(request, for: "key")

        await store.remove(for: "key")

        #expect(await store.load(for: "key") == nil)
    }

    @Test("allKeys reflects saved and removed keys")
    func allKeysReflectsState() async {
        let store = InMemoryMutationStore()
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/x", method: .post)

        await store.save(request, for: "a")
        await store.save(request, for: "b")
        #expect(Set(await store.allKeys()) == ["a", "b"])

        await store.remove(for: "a")
        #expect(await store.allKeys() == ["b"])
    }

    @Test("Persisted requests survive a JSON round trip, proving durable storage is feasible")
    func persistedRequestsSurviveJSONRoundTrip() async throws {
        let store = InMemoryMutationStore()
        let request = MutationRequest(
            baseURL: "https://api.test.com",
            path: "/videos/42/like",
            method: .post,
            authorization: .bearer(token: "secret-token"),
            body: Data("{\"liked\":true}".utf8)
        )
        await store.save(request, for: "like:video:42")

        let loaded = try #require(await store.load(for: "like:video:42"))
        let data = try JSONEncoder().encode(loaded)
        let replayed = try JSONDecoder().decode(MutationRequest.self, from: data)

        #expect(replayed == request)
    }
}
