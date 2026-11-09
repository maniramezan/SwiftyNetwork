import Foundation
import Testing

@testable import SwiftyNetwork

// The recipe in SwiftyNetwork.docc/CustomDiskCache.md. Keep the two in sync.

actor DiskCache<Value: Codable & Sendable>: Cache {
    private struct Envelope: Codable {
        var timestamp: Date
        var value: Value
    }

    private let directory: URL
    private let maxAge: Duration
    private let maxBytes: Int
    private let fileManager = FileManager.default

    init(directory: URL, maxAge: Duration = .seconds(7 * 24 * 3600), maxBytes: Int = 50_000_000) throws {
        self.directory = directory
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func entry(forKey key: CacheKey) -> CacheEntry<Value>? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        // Touch only the modification date: it orders files for LRU eviction.
        // The write time stays in the envelope, so reads never change the entry's age.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return CacheEntry(envelope.value, timestamp: envelope.timestamp)
    }

    func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) {
        guard let data = try? JSONEncoder().encode(Envelope(timestamp: entry.timestamp, value: entry.value)) else {
            return
        }
        try? data.write(to: fileURL(for: key), options: .atomic)
        prune()
    }

    func removeValue(forKey key: CacheKey) {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    func removeAll() {
        for file in files() { try? fileManager.removeItem(at: file.url) }
    }

    private func fileURL(for key: CacheKey) -> URL {
        let name = Data(key.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func files() -> [(url: URL, modified: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let modified = values.contentModificationDate,
                let size = values.fileSize
            else { return nil }
            return (url, modified, size)
        }
    }

    // Drops files not used within `maxAge`, then the least recently used until under `maxBytes`.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-(maxAge / .seconds(1)))
        var remaining: [(url: URL, modified: Date, size: Int)] = []
        for file in files() {
            if file.modified < cutoff {
                try? fileManager.removeItem(at: file.url)
            } else {
                remaining.append(file)
            }
        }
        var total = remaining.reduce(0) { $0 + $1.size }
        for file in remaining.sorted(by: { $0.modified < $1.modified }) where total > maxBytes {
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}

@Suite("Disk cache recipe")
struct DiskCacheRecipeTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("disk-cache-\(UUID().uuidString)")
    }

    @Test("Reads keep the original write timestamp")
    func readsPreserveTimestamp() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DiskCache<String>(directory: directory)
        let written = Date(timeIntervalSinceNow: -3600)

        await cache.setEntry(CacheEntry("hello", timestamp: written), forKey: "greeting")
        let first = await cache.entry(forKey: "greeting")
        let second = await cache.entry(forKey: "greeting")

        #expect(first?.value == "hello")
        #expect(first?.timestamp == written)
        #expect(second?.timestamp == written)
    }

    @Test("Reads refresh recency, so the least recently read entry is evicted first")
    func evictsLeastRecentlyUsed() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = String(repeating: "x", count: 1_000)
        let cache = try DiskCache<String>(directory: directory, maxBytes: 2_500)

        await cache.setValue(payload, forKey: "a")
        try await Task.sleep(for: .milliseconds(20))
        await cache.setValue(payload, forKey: "b")
        try await Task.sleep(for: .milliseconds(20))
        _ = await cache.value(forKey: "a")
        try await Task.sleep(for: .milliseconds(20))
        await cache.setValue(payload, forKey: "c")

        #expect(await cache.value(forKey: "a") != nil)
        #expect(await cache.value(forKey: "b") == nil)
        #expect(await cache.value(forKey: "c") != nil)
    }

    @Test("removeValue and removeAll delete entries")
    func removal() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DiskCache<Int>(directory: directory)
        await cache.setValue(1, forKey: "a")
        await cache.setValue(2, forKey: "b")

        await cache.removeValue(forKey: "a")
        #expect(await cache.value(forKey: "a") == nil)
        await cache.removeAll()
        #expect(await cache.value(forKey: "b") == nil)
    }
}
