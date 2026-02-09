import Foundation

// MARK: - Package Constants

/// The package name used for logging and debugging.
public let swiftyNetworkPackageName = "SwiftyNetwork"

// MARK: - NSLog Helper

/// Logs a message using NSLog with file and line information.
///
/// - Parameters:
///   - message: The message to log.
///   - file: The file where the log was called (auto-populated).
///   - line: The line number where the log was called (auto-populated).
func nslog(
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let fileName = (file as NSString).lastPathComponent
    NSLog("[\(fileName):\(line)] \(message)")
}

// MARK: - Logging Helper

/// Internal logging helper that provides consistent, prefixed logging throughout the package.
///
/// This uses NSLog under the hood for system-level logging that integrates with Console.app.
enum Logger {
    /// Logs an informational message.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - file: The file where the log was called (auto-populated).
    ///   - line: The line number where the log was called (auto-populated).
    static func info(
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        nslog("[\(swiftyNetworkPackageName)] ℹ️ \(message)", file: file, line: line)
    }

    /// Logs a warning message.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - file: The file where the log was called (auto-populated).
    ///   - line: The line number where the log was called (auto-populated).
    static func warning(
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        nslog("[\(swiftyNetworkPackageName)] ⚠️ \(message)", file: file, line: line)
    }

    /// Logs an error message.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - error: An optional error to include in the log.
    ///   - file: The file where the log was called (auto-populated).
    ///   - line: The line number where the log was called (auto-populated).
    static func error(
        _ message: String,
        error: Error? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let errorDetail = error.map { " - Error: \($0)" } ?? ""
        nslog("[\(swiftyNetworkPackageName)] ❌ \(message)\(errorDetail)", file: file, line: line)
    }

    /// Logs a debug message (only in DEBUG builds).
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - file: The file where the log was called (auto-populated).
    ///   - line: The line number where the log was called (auto-populated).
    static func debug(
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        #if DEBUG
            nslog("[\(swiftyNetworkPackageName)] 🐛 \(message)", file: file, line: line)
        #endif
    }
}
