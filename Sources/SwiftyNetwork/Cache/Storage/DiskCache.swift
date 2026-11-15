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
/// - **When the value was last used** is the file's modification date, which a read refreshes at
///   most once a minute. It orders entries for eviction, so entries read within the same minute
///   may be evicted in either order.
///
/// Two optional limits bound the directory. Writing more than `maxBytes` evicts the least recently
/// used entries, and entries not used within `maxIdleTime` are removed. Call ``prune()`` to apply
/// both limits on demand, for example at launch.
///
/// Files are named by a hash of the key and the directory is excluded from backups. Values are
/// stored as given, without encryption; pass a directory with the file protection your data needs.
/// Use one `DiskCache` per directory and don't write to the directory yourself.
///
/// Operations for one key run in order. Different keys are read, decoded, and written in
/// parallel, off the cache's actor, so a screen of images loads its files side by side.
/// ``removeAll()``, ``prune()``, and eviction wait for running operations and hold back later
/// ones. It suits values up to a few megabytes, such as API responses and images.
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

    private enum ReadOutcome: Sendable {
        case hit(CacheEntry<Value>)
        case miss
        /// The file was idle or unreadable and was removed.
        case removed(bytes: Int)
    }

    private enum WriteOutcome: Sendable {
        case unchanged
        /// The value could never fit, so the entry it would have replaced was removed.
        case removed(bytes: Int)
        case written(delta: Int)
    }

    /// Marks a file as written by this type and names its layout.
    private static var magic: [UInt8] { Array("SNC1".utf8) }

    /// After exceeding `maxBytes`, evict down to this fraction of it, so a full cache does not
    /// scan the directory on every write.
    private static var evictionTarget: Double { 0.9 }

    /// The longest a read leaves an entry's last-used time unrefreshed, in seconds.
    private static var maxRecencyGranularity: TimeInterval { 60 }

    private let directory: URL
    private let maxBytes: Int?
    private let maxIdleTime: Duration?

    /// A read refreshes the last-used time only when it is at least this old, so repeated reads
    /// of one entry don't each write to the file system. It stays under half of `maxIdleTime`,
    /// so an entry that keeps being read never goes idle.
    private let recencyGranularity: TimeInterval
    private let encode: @Sendable (Value) throws -> Data
    private let decode: @Sendable (Data) throws -> Value
    private let fileManager = FileManager()

    /// Orders operations per key; eviction, pruning, and clearing run alone.
    private let operations = CacheOperationGate<CacheKey>()

    /// The size of the directory's files, or `nil` until a write under a size limit measures it.
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
        self.recencyGranularity = min(
            Self.maxRecencyGranularity,
            maxIdleTime.map { max(0, $0.timeInterval / 2) } ?? Self.maxRecencyGranularity
        )
        self.encode = encode
        self.decode = decode
    }

    // MARK: - Cache API

    /// Reads the entry for `key` and marks it as used.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The value and the time it was written, or `nil` when nothing usable is stored.
    public func entry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        await operations.run(for: key) { await self.readEntry(forKey: key) }
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
        let exceedsLimit = await operations.run(for: key) { await self.writeEntry(entry, forKey: key) }
        guard exceedsLimit, let maxBytes else { return }
        // Eviction removes other keys' files, so it runs alone, after this key's write is released.
        await operations.runExclusive {
            await self.evict(downTo: Int(Double(maxBytes) * Self.evictionTarget))
        }
    }

    /// Removes the entry for `key`.
    ///
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        await operations.run(for: key) { await self.removeEntry(forKey: key) }
    }

    /// Removes every entry.
    public func removeAll() async {
        await operations.runExclusive { await self.removeAllFiles() }
    }

    // MARK: - Maintenance

    /// Removes entries not used within `maxIdleTime`, then evicts least recently used entries
    /// until the directory is within `maxBytes`.
    ///
    /// Writes apply the size limit on their own. Call this to apply the idle limit, for example
    /// once at launch.
    public func prune() async {
        await operations.runExclusive { await self.pruneFiles() }
    }

    /// The total size of the stored files, in bytes.
    ///
    /// - Returns: The directory's current size.
    public func totalSize() async -> Int {
        await operations.runExclusive { await self.measureTotalBytes() }
    }

    // MARK: - Gated Operations

    // Each runs inside the gate. The file work itself runs off the actor, so operations for
    // different keys overlap; only the size bookkeeping happens here.

    private func readEntry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        let outcome = await Self.read(
            fileURL(for: key),
            key: key.rawValue,
            maxIdleTime: maxIdleTime?.timeInterval,
            recencyGranularity: recencyGranularity,
            decode: decode
        )
        switch outcome {
        case .hit(let entry):
            return entry
        case .miss:
            return nil
        case .removed(let bytes):
            adjustTotalBytes(by: -bytes)
            return nil
        }
    }

    /// - Returns: `true` when the directory now exceeds `maxBytes`.
    private func writeEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async -> Bool {
        let outcome = await Self.write(
            entry,
            to: fileURL(for: key),
            key: key.rawValue,
            in: isDirectoryReady ? nil : directory,
            maxBytes: maxBytes,
            encode: encode
        )
        switch outcome {
        case .unchanged:
            return false
        case .removed(let bytes):
            adjustTotalBytes(by: -bytes)
            return false
        case .written(let delta):
            isDirectoryReady = true
            guard let maxBytes else { return false }
            if totalBytes == nil {
                // The first write under a size limit measures the directory, this file included.
                totalBytes = files().reduce(0) { $0 + $1.size }
            } else {
                adjustTotalBytes(by: delta)
            }
            return (totalBytes ?? 0) > maxBytes
        }
    }

    private func removeEntry(forKey key: CacheKey) async {
        if let bytes = await Self.remove(fileURL(for: key)) {
            adjustTotalBytes(by: -bytes)
        }
    }

    private func removeAllFiles() {
        var remainingBytes = 0
        for file in files() {
            do {
                try fileManager.removeItem(at: file.url)
            } catch {
                Logger.warning("Could not remove a disk cache entry", category: .cache)
                remainingBytes += file.size
            }
        }
        totalBytes = remainingBytes
    }

    private func pruneFiles() {
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

    private func measureTotalBytes() -> Int {
        let total = files().reduce(0) { $0 + $1.size }
        totalBytes = total
        return total
    }

    // MARK: - Private Helpers

    private func fileURL(for key: CacheKey) -> URL {
        directory.appendingPathComponent(HashedFileName.make(for: key.rawValue), isDirectory: false)
    }

    private func adjustTotalBytes(by delta: Int) {
        if let totalBytes {
            self.totalBytes = max(0, totalBytes + delta)
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

    // MARK: - File Work

    // `@concurrent` runs these on the global executor, off the cache's actor.

    /// Reads, validates, and decodes the file at `url`, removing it when it is idle or unreadable.
    @concurrent
    private static func read(
        _ url: URL,
        key: String,
        maxIdleTime: TimeInterval?,
        recencyGranularity: TimeInterval,
        decode: @Sendable (Data) throws -> Value
    ) async -> ReadOutcome {
        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                Logger.warning("Could not read a disk cache entry", category: .cache)
            }
            return .miss
        }
        let now = Date()
        let lastUsed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let maxIdleTime, let lastUsed, lastUsed < now.addingTimeInterval(-maxIdleTime) {
            return removeFile(at: url) ? .removed(bytes: contents.count) : .miss
        }
        guard let stored = parse(contents), stored.key == key,
            let value = try? decode(stored.payload)
        else {
            // Not written by this cache, written for another key, or no longer decodable.
            Logger.debug("Removing an unreadable disk cache entry", category: .cache)
            return removeFile(at: url) ? .removed(bytes: contents.count) : .miss
        }
        // Only the modification date moves on a read; the write time stays in the file.
        if lastUsed.map({ $0 < now.addingTimeInterval(-recencyGranularity) }) ?? true {
            do {
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            } catch {
                Logger.warning("Could not update disk cache recency", category: .cache)
            }
        }
        return .hit(CacheEntry(value, timestamp: stored.timestamp))
    }

    /// Encodes and writes `entry` to `url`.
    ///
    /// - Parameter directory: The directory to create and exclude from backups first, or `nil`
    ///   when it is already prepared.
    @concurrent
    private static func write(
        _ entry: CacheEntry<Value>,
        to url: URL,
        key: String,
        in directory: URL?,
        maxBytes: Int?,
        encode: @Sendable (Value) throws -> Data
    ) async -> WriteOutcome {
        guard let payload = try? encode(entry.value) else {
            Logger.warning("Could not encode a value for the disk cache", category: .cache)
            return .unchanged
        }
        let contents = serialize(key: key, timestamp: entry.timestamp, payload: payload)
        let replacedSize = size(of: url)
        if let maxBytes, contents.count > maxBytes {
            // It can never fit: drop the entry it would have replaced and store nothing.
            guard let replacedSize, removeFile(at: url) else { return .unchanged }
            return .removed(bytes: replacedSize)
        }
        if var directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                Logger.warning("Could not create the disk cache directory", category: .cache)
                return .unchanged
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        do {
            try contents.write(to: url, options: .atomic)
        } catch {
            Logger.warning("Could not write a disk cache entry", category: .cache)
            return .unchanged
        }
        return .written(delta: contents.count - (replacedSize ?? 0))
    }

    /// - Returns: The size of the removed file, or `nil` when there was none or it could not be removed.
    @concurrent
    private static func remove(_ url: URL) async -> Int? {
        guard let size = size(of: url), removeFile(at: url) else { return nil }
        return size
    }

    private static func removeFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            Logger.warning("Could not remove a disk cache entry", category: .cache)
            return false
        }
    }

    private static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
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
