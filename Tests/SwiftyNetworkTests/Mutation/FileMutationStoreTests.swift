import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("FileMutationStore Tests")
struct FileMutationStoreTests {
    private func makeRequest(path: String) -> MutationRequest {
        MutationRequest(baseURL: "https://api.test.com", path: path, method: .post)
    }

    @Test("Pending mutations survive creating a new store for the same directory")
    func persistsAcrossInstances() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = makeRequest(path: "/likes")
        let first = FileMutationStore(directory: directory)

        await first.save(request, for: "like:1")
        let reopened = FileMutationStore(directory: directory)

        #expect(await reopened.load(for: "like:1") == request)
        #expect(await reopened.allKeys() == ["like:1"])
    }

    @Test("removeIfCurrent preserves a newer coalesced request")
    func removesOnlyTheCurrentRequest() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationStore(directory: directory)
        let old = makeRequest(path: "/old")
        let replacement = makeRequest(path: "/new")

        await store.save(old, for: "key")
        await store.save(replacement, for: "key")
        let removedOld = await store.removeIfCurrent(old, for: "key")
        let current = await store.load(for: "key")
        let removedReplacement = await store.removeIfCurrent(replacement, for: "key")

        #expect(!removedOld)
        #expect(current == replacement)
        #expect(removedReplacement)
        #expect(await store.allKeys().isEmpty)
    }
}
