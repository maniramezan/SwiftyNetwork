import Foundation
internal import SwiftCommons

/// A durable ``MutationStore`` that keeps each pending mutation in its own file.
///
/// Pending mutations survive the app being terminated. Create the store once, pass it to a
/// ``MutationQueue``, and call ``MutationQueue/resumePendingMutations()`` at launch to replay
/// what was pending:
///
/// ```swift
/// let directory = URL.applicationSupportDirectory.appending(path: "PendingMutations", directoryHint: .isDirectory)
/// let queue = MutationQueue(client: client, store: FileMutationStore(directory: directory)) {
///     await NetworkMonitor.shared.waitUntilReachable()
/// }
/// await queue.resumePendingMutations()
/// ```
///
/// Requests are stored as JSON, named by a hash of their key, and written atomically. They
/// carry no credentials (see ``MutationRequest``), but their bodies can contain user data and
/// are not encrypted; pass a directory with the file protection your data needs. On iOS the
/// store asks for protection until the first unlock after a restart, so a background launch
/// can still read it. The directory is excluded from backups.
///
/// Use one store per directory, and a directory per signed-in user if mutations must not
/// outlive a session without ``MutationQueue/cancelAll()``. A file that cannot be decoded,
/// for example one written by a newer version of the library, is skipped and left in place.
public actor FileMutationStore: MutationStore {
    private struct Record: Codable {
        let key: MutationKey
        let request: MutationRequest
    }

    private let directory: URL
    private let fileManager = FileManager()
    private let encoder = JSONEncoder()
    private var isDirectoryReady = false

    /// Pending requests by key, read from disk on first use and kept in step with it.
    private var requests: [MutationKey: MutationRequest]?

    /// Creates a file-backed mutation store.
    ///
    /// - Parameter directory: Where pending mutations are stored. Created on first write. Use a
    ///   location that is not purged by the system, such as a folder under
    ///   `URL.applicationSupportDirectory`; a cache directory can lose pending mutations.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Persists `request` as the current desired state for `key`.
    ///
    /// If the file cannot be written, the request is still kept in memory for this launch.
    ///
    /// - Parameters:
    ///   - request: The mutation to persist.
    ///   - key: The logical mutation this request belongs to.
    public func save(_ request: MutationRequest, for key: MutationKey) async {
        var loaded = loadedRequests()
        loaded[key] = request
        requests = loaded
        write(Record(key: key, request: request))
    }

    /// Returns the currently persisted request for `key`, if any.
    ///
    /// - Parameter key: The logical mutation to look up.
    public func load(for key: MutationKey) async -> MutationRequest? {
        loadedRequests()[key]
    }

    /// Removes any persisted request for `key`.
    ///
    /// - Parameter key: The logical mutation to clear.
    public func remove(for key: MutationKey) async {
        var loaded = loadedRequests()
        loaded[key] = nil
        requests = loaded
        removeFile(for: key)
    }

    /// Removes `request` for `key` only if it is still the persisted value.
    ///
    /// - Parameters:
    ///   - request: The value the caller just finished processing.
    ///   - key: The logical mutation to clear.
    /// - Returns: `true` if `request` was still current and was removed.
    public func removeIfCurrent(_ request: MutationRequest, for key: MutationKey) async -> Bool {
        var loaded = loadedRequests()
        guard loaded[key] == request else { return false }
        loaded[key] = nil
        requests = loaded
        removeFile(for: key)
        return true
    }

    /// Returns every key with a persisted request.
    public func allKeys() async -> [MutationKey] {
        Array(loadedRequests().keys)
    }

    // MARK: - Private Helpers

    private func fileURL(for key: MutationKey) -> URL {
        directory
            .appendingPathComponent(HashedFileName.make(for: key.rawValue), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func loadedRequests() -> [MutationKey: MutationRequest] {
        if let requests { return requests }
        var loaded: [MutationKey: MutationRequest] = [:]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            if fileManager.fileExists(atPath: directory.path) {
                Logger.error("Could not read the persisted mutations directory", error: error, category: .mutation)
            }
            requests = loaded
            return loaded
        }
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                let record = try? decoder.decode(Record.self, from: data)
            else {
                Logger.warning("Skipping a persisted mutation that could not be read", category: .mutation)
                continue
            }
            guard url.lastPathComponent == fileURL(for: record.key).lastPathComponent else {
                Logger.warning("Skipping a persisted mutation with a mismatched key", category: .mutation)
                continue
            }
            loaded[record.key] = record.request
        }
        requests = loaded
        return loaded
    }

    private func removeFile(for key: MutationKey) {
        let url = fileURL(for: key)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                Logger.error(
                    "Could not remove a persisted mutation; it may replay after relaunch", error: error,
                    category: .mutation)
            }
        }
    }

    private func write(_ record: Record) {
        do {
            try prepareDirectory()
            let data = try encoder.encode(record)
            let url = fileURL(for: record.key)
            do {
                try data.write(to: url, options: Self.writingOptions)
            } catch {
                // The directory may have been removed since it was prepared: recreate it and retry.
                isDirectoryReady = false
                try prepareDirectory()
                try data.write(to: url, options: Self.writingOptions)
            }
        } catch {
            Logger.error("Could not persist a mutation; it is kept in memory only", error: error, category: .mutation)
        }
    }

    /// Creates the directory and excludes it from backups, once.
    private func prepareDirectory() throws {
        if isDirectoryReady { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(values)
        isDirectoryReady = true
    }

    private static var writingOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            [.atomic]
        #endif
    }
}
