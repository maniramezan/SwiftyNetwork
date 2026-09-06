import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("Cache operation ordering")
struct CacheOrderingTests {
    @Test("Invalidation rejects a fetch that ignores cancellation", arguments: [false, true])
    func invalidationRejectsLateFetch(removeAll: Bool) async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let started = Gate()
        let finish = Gate()
        let key = CacheKey("key")
        let old = Task {
            try await cache.value(forKey: key) {
                await started.open()
                await finish.wait()
                return "stale"
            }
        }
        await started.wait()
        if removeAll { await cache.removeAll() } else { await cache.removeValue(forKey: key) }
        let replacementStarted = Gate()
        let replacementFinish = Gate()
        let replacement = Task {
            try await cache.value(forKey: key) {
                await replacementStarted.open()
                await replacementFinish.wait()
                return "fresh"
            }
        }
        await replacementStarted.wait()
        await finish.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await cache.value(forKey: key) == nil)
        await replacementFinish.open()
        #expect(try await replacement.value == "fresh")
        #expect(await cache.value(forKey: key) == "fresh")
    }

    @Test("Different keys can fetch while another fetch is suspended")
    func independentFetches() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let firstStarted = Gate()
        let finish = Gate()
        let first = Task {
            try await cache.value(forKey: CacheKey("first")) {
                await firstStarted.open()
                await finish.wait()
                return "first"
            }
        }
        await firstStarted.wait()
        let second = try await cache.value(forKey: CacheKey("second")) { "second" }
        #expect(second == "second")
        await finish.open()
        #expect(try await first.value == "first")
    }

    @Test("An explicit write supersedes a suspended fetch")
    func explicitWriteWins() async {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let started = Gate()
        let finish = Gate()
        let key = CacheKey("key")
        let fetch = Task {
            try await cache.value(forKey: key) {
                await started.open()
                await finish.wait()
                return "stale"
            }
        }
        await started.wait()
        await cache.setValue("explicit", forKey: key)
        await finish.open()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(await cache.value(forKey: key) == "explicit")
    }

    @Test("Canceling one caller preserves the shared fetch for other callers")
    func canceledCallerDoesNotCancelFetch() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let started = Gate()
        let finish = Gate()
        let key = CacheKey("key")
        let caller = Task {
            try await cache.value(forKey: key) {
                await started.open()
                await finish.wait()
                try Task.checkCancellation()
                return "shared"
            }
        }
        await started.wait()
        caller.cancel()
        await finish.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        let value = try await cache.value(forKey: key) {
            Issue.record("Canceling a caller must not discard shared work")
            return "unexpected"
        }
        #expect(value == "shared")
    }

    @Test("Removal follows a suspended fetch commit")
    func removalDuringCommit() async throws {
        let storage = SuspendedWriteCache()
        let cache = SingleFlightCache(storage)
        let key = CacheKey("key")
        let fetch = Task { try await cache.value(forKey: key) { "value" } }
        await storage.writeStarted.wait()
        let removal = Task { await cache.removeValue(forKey: key) }
        while await cache.operations.queuedOperationCount == 0 { await Task.yield() }
        await storage.finishWrite.open()
        _ = try await fetch.value
        await removal.value
        #expect(await cache.value(forKey: key) == nil)
    }

    @Test("Layered writes keep both tiers consistent while persistence suspends")
    func layeredWritesStayConsistent() async {
        let memory = InMemoryCache<String>()
        let persistent = SuspendedWriteCache()
        let cache = LayeredCache(memoryCache: memory, persistentCache: persistent)
        let key = CacheKey("key")
        let first = Task { await cache.setValue("first", forKey: key) }
        await persistent.writeStarted.wait()
        let second = Task { await cache.setValue("second", forKey: key) }
        while await cache.operations.queuedOperationCount == 0 { await Task.yield() }
        await persistent.finishWrite.open()
        await first.value
        await second.value
        #expect(await memory.value(forKey: key) == "second")
        #expect(await persistent.value(forKey: key) == "second")
    }

    @Test("Layered removal follows suspended promotion", arguments: [false, true])
    func layeredRemovalDuringPromotion(removeAll: Bool) async {
        let memory = SuspendedWriteCache()
        let persistent = InMemoryCache<String>()
        let key = CacheKey("key")
        await persistent.setValue("persisted", forKey: key)
        let cache = LayeredCache(memoryCache: memory, persistentCache: persistent)
        let read = Task { await cache.value(forKey: key) }
        await memory.writeStarted.wait()
        let removal = Task {
            if removeAll { await cache.removeAll() } else { await cache.removeValue(forKey: key) }
        }
        while await cache.operations.queuedOperationCount == 0 { await Task.yield() }
        await memory.finishWrite.open()
        #expect(await read.value == "persisted")
        await removal.value
        #expect(await memory.value(forKey: key) == nil)
        #expect(await persistent.value(forKey: key) == nil)
    }
}

/// Suspends the first write before storing, without relying on timing or sleeps.
private actor SuspendedWriteCache: TimestampedCache {
    let writeStarted = Gate()
    let finishWrite = Gate()
    private var suspendNextWrite = true
    private var storage: [CacheKey: (String, Date)] = [:]

    func value(forKey key: CacheKey) async -> String? { storage[key]?.0 }
    func timestamp(forKey key: CacheKey) async -> Date? { storage[key]?.1 }
    func removeValue(forKey key: CacheKey) async { storage[key] = nil }
    func removeAll() async { storage.removeAll() }
    func setValue(_ value: String, forKey key: CacheKey) async {
        await setValue(value, forKey: key, timestamp: Date())
    }
    func setValue(_ value: String, forKey key: CacheKey, timestamp: Date) async {
        if suspendNextWrite {
            suspendNextWrite = false
            await writeStarted.open()
            await finishWrite.wait()
        }
        storage[key] = (value, timestamp)
    }
}
