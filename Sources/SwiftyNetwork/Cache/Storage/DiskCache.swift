import Foundation
internal import SwiftCommons

// MARK: - Disk Cache

/// A ``Cache`` that stores each value in its own file, so cached values survive relaunches.
///
/// Use it on its own, or as the persistent tier of a ``LayeredCache`` behind an
/// ``InMemoryCache``. It keeps two times apart for every entry:
///
/// - **When the value was written**, ``CacheEntry/timestamp``, is stored inside the file. Reading a
///   value never changes it, so ``CachePolicy/returnCacheIfNotExpired(maxAge:)`` expires a value by
///   its real age.
/// - **When the value was last used** is the file's modification date, which a read refreshes. It
///   orders entries for eviction.
///
/// Two optional limits bound the directory. Writing more than `maxBytes` evicts the least recently
/// used entries, and entries not used within `maxIdleTime` are removed. Call ``prune()`` to apply
/// both limits on demand, for example at launch.
///
/// Files are named by a hash of the key and the directory is excluded from backups. Values are
/// stored as given, without encryption; pass a directory with the file protection your data needs.
/// Use one `DiskCache` per directory and don't write to the directory yourself.
///
/// File I/O runs on the cache's actor, which keeps writes and removals for a key in order. It suits
/// values up to a few megabytes, such as API responses and images.
///
/// Example:
/// ```swift
/// let directory = URL.cachesDirectory.appending(path: "images", directoryHint: .isDirectory)
/// let disk = DiskCache<Data>(directory: directory, maxBytes: 150_000_000, maxIdleTime: .seconds(7 * 86_400))
/// let images = RemoteDataCache(
///     cache: LayeredCache(memoryCache: InMemoryCache<Data>(maxBytes: 50_000_000), persistentCache: disk)
/// )
///
/// let users = DiskCache<User>(directory: URL.cachesDirectory.appending(path: "users"))
/// ```
public actor DiskCache<Value: Sendable>: Cache {
    private struct File {
        let url: URL
        let lastUsed: Date
        let size: Int
    }

    /// Marks a file as written by this type and names its layout.
    private static var magic: [UInt8] { Array("SNC1".utf8) }

    /// After exceeding `maxBytes`, evict down to this fraction of it, so a full cache does not
    /// scan the directory on every write.
    private static var evictionTarget: Double { 0.9 }

    private let directory: URL
    private let maxBytes: Int?
    private let maxIdleTime: Duration?
    private let encode: @Sendable (Value) throws -> Data
    private let decode: @Sendable (Data) throws -> Value
    private let fileManager = FileManager()

    /// The size of the directory's files, or `nil` until the first write measures it.
    private var totalBytes: Int?
    private var isDirectoryReady = false

    /// Creates a disk cache with a custom byte representation.
    ///
    /// - Parameters:
    ///   - directory: Where the files are stored. Created on first write. Use a location under
    ///     `URL.cachesDirectory` so the system can reclaim the space.
    ///   - maxBytes: The directory's size limit, or `nil` for none. Negative values are treated as `0`.
    ///   - maxIdleTime: How long an entry may go unused before it is removed, or `nil` to keep
    ///     unused entries.
    ///   - encode: Converts a value to the bytes to store.
    ///   - decode: Converts stored bytes back to a value. A stored entry it throws for is removed.
    public init(
        directory: URL,
        maxBytes: Int? = nil,
        maxIdleTime: Duration? = nil,
        encode: @escaping @Sendable (Value) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Value
    ) {
        self.directory = directory
        self.maxBytes = maxBytes.map { max(0, $0) }
        self.maxIdleTime = maxIdleTime
        self.encode = encode
        self.decode = decode
    }

    // MARK: - Cache API

    /// Reads the entry for `key` and marks it as just used.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The value and the time it was written, or `nil` when nothing usable is stored.
    public func entry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        let url = fileURL(for: key)
        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                Logger.warning("Could not read a disk cache entry", category: .cache)
            }
            return nil
        }
        if let maxIdleTime, let lastUsed = lastUsed(of: url),
            lastUsed < Date().addingTimeInterval(-maxIdleTime.timeInterval)
        {
            remove(url, size: contents.count)
            return nil
        }
        guard let stored = Self.parse(contents), stored.key == key.rawValue,
            let value = try? decode(stored.payload)
        else {
            // Not written by this cache, written for another key, or no longer decodable.
            Logger.debug("Removing an unreadable disk cache entry", category: .cache)
            remove(url, size: contents.count)
            return nil
        }
        // Only the modification date moves on a read; the write time stays in the file.
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            Logger.warning("Could not update disk cache recency", category: .cache)
        }
        return CacheEntry(value, timestamp: stored.timestamp)
    }

    /// Writes the entry for `key`, then evicts least recently used entries if the directory
    /// exceeds its size limit.
    ///
    /// A value that cannot be encoded or written is not stored.
    ///
    /// - Parameters:
    ///   - entry: The value and timestamp to store.
    ///   - key: The cache key to associate with the entry.
    public func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async {
        guard let payload = try? encode(entry.value) else {
            Logger.warning("Could not encode a value for the disk cache", category: .cache)
            return
        }
        let contents = Self.serialize(key: key.rawValue, timestamp: entry.timestamp, payload: payload)
        if let maxBytes, contents.count > maxBytes {
            // It can never fit: drop the entry it would have replaced and store nothing.
            await removeValue(forKey: key)
            return
        }
        guard prepareDirectory() else { return }

        let url = fileURL(for: key)
        let measured = measuredTotalBytes()
        let replacedSize = size(of: url) ?? 0
        do {
            try contents.write(to: url, options: .atomic)
        } catch {
            Logger.warning("Could not write a disk cache entry", category: .cache)
            return
        }
        let total = measured - replacedSize + contents.count
        totalBytes = total
        if let maxBytes, total > maxBytes {
            evict(downTo: Int(Double(maxBytes) * Self.evictionTarget))
        }
    }

    /// Removes the entry for `key`.
    ///
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        let url = fileURL(for: key)
        guard let size = size(of: url) else { return }
        remove(url, size: size)
    }

    /// Removes every entry.
    public func removeAll() async {
        for file in files() {
            do {
                try fileManager.removeItem(at: file.url)
            } catch {
                Logger.warning("Could not remove a disk cache entry", category: .cache)
            }
        }
        totalBytes = files().reduce(0) { $0 + $1.size }
    }

    // MARK: - Maintenance

    /// Removes entries not used within `maxIdleTime`, then evicts least recently used entries
    /// until the directory is within `maxBytes`.
    ///
    /// Writes apply the size limit on their own. Call this to apply the idle limit, for example
    /// once at launch.
    public func prune() async {
        var remaining = files()
        if let maxIdleTime {
            let cutoff = Date().addingTimeInterval(-maxIdleTime.timeInterval)
            remaining.removeAll { file in
                guard file.lastUsed < cutoff else { return false }
                do {
                    try fileManager.removeItem(at: file.url)
                    return true
                } catch {
                    Logger.warning("Could not remove an idle disk cache entry", category: .cache)
                    return false
                }
            }
        }
        totalBytes = remaining.reduce(0) { $0 + $1.size }
        if let maxBytes {
            evict(downTo: maxBytes)
        }
    }

    /// The total size of the stored files, in bytes.
    ///
    /// - Returns: The directory's current size.
    public func totalSize() async -> Int {
        let total = files().reduce(0) { $0 + $1.size }
        totalBytes = total
        return total
    }

    // MARK: - Private Helpers

    private func fileURL(for key: CacheKey) -> URL {
        directory.appendingPathComponent(HashedFileName.make(for: key.rawValue), isDirectory: false)
    }

    /// Creates the directory and excludes it from backups, once.
    private func prepareDirectory() -> Bool {
        if isDirectoryReady { return true }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Logger.warning("Could not create the disk cache directory", category: .cache)
            return false
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(values)
        isDirectoryReady = true
        return true
    }

    private func measuredTotalBytes() -> Int {
        if let totalBytes { return totalBytes }
        let total = files().reduce(0) { $0 + $1.size }
        totalBytes = total
        return total
    }

    private func remove(_ url: URL, size: Int) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Logger.warning("Could not remove a disk cache entry", category: .cache)
            return
        }
        if let totalBytes {
            self.totalBytes = max(0, totalBytes - size)
        }
    }

    /// Removes least recently used files until the directory is at most `limit` bytes.
    private func evict(downTo limit: Int) {
        let stored = files()
        var total = stored.reduce(0) { $0 + $1.size }
        for file in stored.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > limit {
            guard (try? fileManager.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            Logger.debug("Evicted a least recently used disk cache entry", category: .cache)
        }
        totalBytes = total
    }

    private func files() -> [File] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: .skipsHiddenFiles
            )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let lastUsed = values.contentModificationDate,
                let size = values.fileSize
            else { return nil }
            return File(url: url, lastUsed: lastUsed, size: size)
        }
    }

    private func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func lastUsed(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - File Layout

    // magic (4 bytes) | write time as IEEE 754 bits (8) | key length (4) | key UTF-8 | payload
    // Integers are big-endian.

    private static func serialize(key: String, timestamp: Date, payload: Data) -> Data {
        let keyBytes = Data(key.utf8)
        var data = Data(capacity: magic.count + 12 + keyBytes.count + payload.count)
        data.append(contentsOf: magic)
        appendBigEndian(timestamp.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        appendBigEndian(UInt32(truncatingIfNeeded: keyBytes.count), to: &data)
        data.append(keyBytes)
        data.append(payload)
        return data
    }

    private static func parse(_ contents: Data) -> (key: String, timestamp: Date, payload: Data)? {
        let bytes = [UInt8](contents.prefix(magic.count + 12))
        guard bytes.count == magic.count + 12, Array(bytes.prefix(magic.count)) == magic else { return nil }
        let timestampBits = bytes[magic.count..<magic.count + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let keyLength = Int(bytes[(magic.count + 8)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let keyStart = contents.startIndex + bytes.count
        guard contents.count - bytes.count >= keyLength else { return nil }
        let payloadStart = keyStart + keyLength
        guard let key = String(data: contents[keyStart..<payloadStart], encoding: .utf8) else { return nil }
        let timestamp = Date(timeIntervalSinceReferenceDate: Double(bitPattern: timestampBits))
        return (key, timestamp, Data(contents[payloadStart...]))
    }

    private static func appendBigEndian<Integer: FixedWidthInteger>(_ value: Integer, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

// MARK: - Convenience Initializers

extension DiskCache where Value == Data {
    /// Creates a disk cache for raw bytes, such as images.
    ///
    /// - Parameters:
    ///   - directory: Where the files are stored. Created on first write.
    ///   - maxBytes: The directory's size limit, or `nil` for none.
    ///   - maxIdleTime: How long an entry may go unused before it is removed, or `nil` to keep
    ///     unused entries.
    public init(directory: URL, maxBytes: Int? = nil, maxIdleTime: Duration? = nil) {
        self.init(directory: directory, maxBytes: maxBytes, maxIdleTime: maxIdleTime, encode: { $0 }, decode: { $0 })
    }
}

extension DiskCache where Value: Codable {
    /// Creates a disk cache that stores values as JSON.
    ///
    /// - Parameters:
    ///   - directory: Where the files are stored. Created on first write.
    ///   - maxBytes: The directory's size limit, or `nil` for none.
    ///   - maxIdleTime: How long an entry may go unused before it is removed, or `nil` to keep
    ///     unused entries.
    ///   - encoder: Encodes values. Defaults to a plain `JSONEncoder`. Don't reconfigure it afterwards.
    ///   - decoder: Decodes values. Defaults to a plain `JSONDecoder`. Don't reconfigure it afterwards.
    public init(
        directory: URL,
        maxBytes: Int? = nil,
        maxIdleTime: Duration? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.init(
            directory: directory,
            maxBytes: maxBytes,
            maxIdleTime: maxIdleTime,
            encode: { try encoder.encode($0) },
            decode: { try decoder.decode(Value.self, from: $0) }
        )
    }
}
