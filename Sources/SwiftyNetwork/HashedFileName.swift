import CryptoKit
import Foundation

/// Derives file names for keys that are stored one file per key.
enum HashedFileName {
    /// The lowercase SHA-256 hex digest of `key`.
    ///
    /// A digest has a fixed length, so long keys stay under the file system's 255-byte name
    /// limit. It is lowercase, so keys that differ only in case cannot share a file on a
    /// case-insensitive volume. It also keeps key contents, such as URLs, out of file names.
    static func make(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0" + hex : hex
            }
            .joined()
    }
}
