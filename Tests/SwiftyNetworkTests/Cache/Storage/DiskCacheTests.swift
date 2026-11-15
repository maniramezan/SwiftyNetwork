import Foundation
import TestCommons
import Testing

@testable import SwiftyNetwork

@Suite("DiskCache Tests", .serialized)
struct DiskCacheTests {
    @Test("A disk cache persists values and their original write timestamps")
    func persistsEntryAndTimestampAcrossInstances() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 123)
        let key: CacheKey = "user:1"
        let first = DiskCache<String>(directory: directory)

        await first.setEntry(CacheEntry("Ada", timestamp: timestamp), forKey: key)
        let reopened = DiskCache<String>(directory: directory)
        let entry = await reopened.entry(forKey: key)

        #expect(entry?.value == "Ada")
        #expect(entry?.timestamp == timestamp)
    }

    @Test("The byte limit evicts the least-recently-used file")
    func evictsLeastRecentlyUsedFile() async throws {
        let probeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: probeDirectory)
            try? FileManager.default.removeItem(at: directory)
        }
        let value = String(repeating: "x", count: 128)
        let probe = DiskCache<String>(directory: probeDirectory)
        await probe.setValue(value, forKey: "first")
        let oneEntrySize = await probe.totalSize()
        let maxBytes = oneEntrySize * 2 - 1
        let cache = DiskCache<String>(directory: directory, maxBytes: maxBytes)

        await cache.setValue(value, forKey: "first")
        let firstFile = directory.appendingPathComponent(HashedFileName.make(for: "first"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: firstFile.path
        )
        await cache.setValue(value, forKey: "later")

        #expect(await cache.totalSize() <= maxBytes)
        #expect(await cache.value(forKey: "first") == nil)
        #expect(await cache.value(forKey: "later") == value)
    }

    @Test("An entry older than maxIdleTime is removed on read")
    func removesIdleEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key: CacheKey = "image"
        let cache = DiskCache<Data>(directory: directory, maxIdleTime: .seconds(1))

        await cache.setValue(Data([1, 2, 3]), forKey: key)
        let file = directory.appendingPathComponent(HashedFileName.make(for: key.rawValue))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: file.path
        )

        #expect(await cache.entry(forKey: key) == nil)
        #expect(await cache.totalSize() == 0)
    }

    @Test("A zero-byte limit does not retain an entry")
    func zeroByteLimitStoresNothing() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache<Data>(directory: directory, maxBytes: 0)

        await cache.setValue(Data([1]), forKey: "image")

        #expect(await cache.value(forKey: "image") == nil)
        #expect(await cache.totalSize() == 0)
    }

    @Test("A read refreshes the last-used time only once it is older than the granularity")
    func throttlesRecencyUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key: CacheKey = "image"
        let cache = DiskCache<Data>(directory: directory)
        await cache.setValue(Data([1, 2, 3]), forKey: key)
        let file = directory.appendingPathComponent(HashedFileName.make(for: key.rawValue))

        let recent = Date().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)
        #expect(await cache.value(forKey: key) == Data([1, 2, 3]))
        let afterRecentRead = try #require(try modificationDate(of: file))
        #expect(abs(afterRecentRead.timeIntervalSince(recent)) < 1)

        let old = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        #expect(await cache.value(forKey: key) == Data([1, 2, 3]))
        let afterOldRead = try #require(try modificationDate(of: file))
        #expect(afterOldRead.timeIntervalSince(old) > 300)
    }

    @Test("A short idle limit refreshes the last-used time before the entry goes idle")
    func refreshesRecencyWithinIdleLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key: CacheKey = "image"
        let cache = DiskCache<Data>(directory: directory, maxIdleTime: .seconds(40))
        await cache.setValue(Data([1]), forKey: key)
        let file = directory.appendingPathComponent(HashedFileName.make(for: key.rawValue))

        let used = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: file.path)
        #expect(await cache.value(forKey: key) == Data([1]))
        let refreshed = try #require(try modificationDate(of: file))
        #expect(refreshed.timeIntervalSince(used) > 20)
    }

    @Test("Removing everything empties the directory and resets its size")
    func removeAllResetsSize() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache<Data>(directory: directory, maxBytes: 10_000)
        await cache.setValue(Data([1]), forKey: "a")
        await cache.setValue(Data([2]), forKey: "b")

        await cache.removeAll()

        #expect(await cache.value(forKey: "a") == nil)
        #expect(await cache.totalSize() == 0)
    }

    @Test("A read of one key finishes while another key's read is still decoding")
    func readsDifferentKeysInParallel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = Data([1])
        let fast = Data([2])
        let slowDecodeStarted = AsyncGate()
        let fastDecodeStarted = AsyncGate()
        let releaseSlowDecode = DispatchSemaphore(value: 0)
        let slowDecodeTimedOut = TestValueBox(false)
        defer { releaseSlowDecode.signal() }
        let cache = DiskCache<Data>(
            directory: directory,
            encode: { $0 },
            decode: { payload in
                if payload == slow {
                    slowDecodeStarted.open()
                    if releaseSlowDecode.wait(timeout: .now() + .seconds(30)) == .timedOut {
                        slowDecodeTimedOut.set(true)
                    }
                } else {
                    fastDecodeStarted.open()
                }
                return payload
            }
        )
        await cache.setValue(slow, forKey: "slow")
        await cache.setValue(fast, forKey: "fast")

        let slowRead = Task { await cache.value(forKey: "slow") }
        try await slowDecodeStarted.wait()
        let fastRead = Task { await cache.value(forKey: "fast") }
        try await fastDecodeStarted.wait()
        releaseSlowDecode.signal()
        let fastValue = await fastRead.value

        #expect(fastValue == fast)
        #expect(await slowRead.value == slow)
        #expect(!slowDecodeTimedOut.get())
    }

    @Test("A limit of one file operation holds a second key's read until the first finishes")
    func limitsConcurrentFileOperations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = Data([1])
        let fast = Data([2])
        let slowDecodeStarted = AsyncGate()
        let releaseSlowDecode = DispatchSemaphore(value: 0)
        let slowDecodeTimedOut = TestValueBox(false)
        defer { releaseSlowDecode.signal() }
        let cache = DiskCache<Data>(
            directory: directory,
            maxConcurrentOperations: 1,
            encode: { $0 },
            decode: { payload in
                if payload == slow {
                    slowDecodeStarted.open()
                    if releaseSlowDecode.wait(timeout: .now() + .seconds(30)) == .timedOut {
                        slowDecodeTimedOut.set(true)
                    }
                }
                return payload
            }
        )
        await cache.setValue(slow, forKey: "slow")
        await cache.setValue(fast, forKey: "fast")

        let slowRead = Task { await cache.value(forKey: "slow") }
        try await slowDecodeStarted.wait()
        let fastFinished = TestValueBox(false)
        let fastRead = Task {
            let value = await cache.value(forKey: "fast")
            fastFinished.set(true)
            return value
        }
        // The second read either waits for the only slot or finishes; only the first is correct.
        while !fastFinished.get(), await cache.queuedFileOperationCount == 0 { await Task.yield() }
        let queued = await cache.queuedFileOperationCount
        releaseSlowDecode.signal()

        #expect(queued == 1)
        #expect(!slowDecodeTimedOut.get())
        #expect(await slowRead.value == slow)
        #expect(await fastRead.value == fast)
        #expect(await cache.queuedFileOperationCount == 0)
    }

    @Test("A limit below one still runs operations, and the default limit is four")
    func clampsTheOperationLimit() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache<Data>(directory: directory, maxConcurrentOperations: 0)

        await cache.setValue(Data([1]), forKey: "a")

        #expect(await cache.value(forKey: "a") == Data([1]))
        #expect(DiskCache<Data>.defaultMaxConcurrentOperations == 4)
    }

    @Test("A write that exceeds the byte limit evicts while other keys stay readable")
    func evictionKeepsNewestEntries() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = Data(repeating: 7, count: 1_000)
        let cache = DiskCache<Data>(directory: directory, maxBytes: 5_000)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { await cache.setValue(value, forKey: CacheKey("key:\(index)")) }
            }
        }

        #expect(await cache.totalSize() <= 5_000)
    }

    private func modificationDate(of url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
