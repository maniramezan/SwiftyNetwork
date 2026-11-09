# Writing a disk-backed cache

Persist cached values across launches with a custom ``Cache``, keeping the write time and
the last-use time apart.

## Overview

SwiftyNetwork ships ``InMemoryCache`` but no on-disk cache, because the right storage depends on your
values: files, a database, or SwiftData. The ``Cache`` protocol has four requirements, so a disk cache is small. The
one decision that is easy to get wrong is time.

A disk cache needs two different times for each entry:

- **When the value was written.** This is ``CacheEntry/timestamp``. ``CachePolicy/returnCacheIfNotExpired(maxAge:)``
  and ``CacheEntry/age(at:)`` read it to decide whether the value is stale. It must not change when
  the value is read.
- **When the value was last used.** This orders entries for least-recently-used eviction. It changes
  on every read.

If you store both in the file's modification date, they conflict. Touching the file on a read to
refresh its LRU position also makes the entry look freshly written, so a value that was fetched a week ago
never expires while the app keeps reading it.

Keep the two apart. Store the write time **inside** the file, next to the value, and use the file's
modification date only for recency. ``Cache/entry(forKey:)`` returns the stored time, and touches the
modification date.

## A complete example

`DiskCache` stores each value as a JSON file in a directory. A read touches only the
modification date. Writing prunes files that were not used within `maxAge`, then evicts the least recently used files
until the directory is under `maxBytes`.

```swift
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
```

Use it anywhere a ``Cache`` goes:

```swift
let directory = URL.cachesDirectory.appending(path: "users", directoryHint: .isDirectory)
let cache = try DiskCache<User>(directory: directory)
let repository = GenericRepository<User>(client: client, cache: cache)
```

To keep hot values in memory, put it behind a ``LayeredCache``:

```swift
let layered = LayeredCache(memoryCache: InMemoryCache<User>(), persistentCache: cache)
```

### Notes

- The file I/O runs on the actor, which is fine for small values. For large payloads, move
  the reads and writes into `@concurrent` functions so they don't block other cache calls.
- `maxAge` prunes by last use, as eviction does. Expiry by write time is the job of
  ``CachePolicy/returnCacheIfNotExpired(maxAge:)``, which reads ``CacheEntry/timestamp``.
- Use `URL.cachesDirectory` so the system can reclaim the space. A cache in
  `URL.documentsDirectory` is backed up unless you exclude it.
- Don't log keys or values: they can contain user data.
