import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("DiskCache Tests")
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
}
