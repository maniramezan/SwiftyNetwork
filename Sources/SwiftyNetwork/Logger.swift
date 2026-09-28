import Foundation
import os

// MARK: - Public Log Level

/// Controls which messages SwiftyNetwork emits to the unified logging system.
///
/// Levels are ordered from least to most verbose. Setting a level enables that
/// level and all higher-severity levels.
///
/// Example:
/// ```swift
/// let configuration = NetworkClientConfiguration(logLevel: .debug)
/// let client = NetworkClient(configuration: configuration)
/// ```
public enum LogLevel: Int, Sendable, Comparable {
    /// Emit no log messages.
    case off = 0
    /// Emit only error-level messages.
    case error = 1
    /// Emit warnings and errors.
    case warning = 2
    /// Emit informational messages, warnings, and errors.
    case info = 3
    /// Emit all messages including debug-level diagnostics.
    case debug = 4

    /// Returns whether the left-hand level is less verbose than the right-hand level.
    ///
    /// This enables comparisons such as `if logLevel >= .warning` when filtering
    /// messages by severity.
    ///
    /// - Parameters:
    ///   - lhs: The first log level.
    ///   - rhs: The second log level.
    /// - Returns: `true` when `lhs` has a lower raw severity value than `rhs`.
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Internal Logger

/// Internal logging facade that bridges SwiftyNetwork to ``os.Logger``.
///
/// All log calls are routed through ``os.Logger`` for structured, privacy-aware
/// system logging. The active level is process-wide and can be changed via
/// ``NetworkClientConfiguration/logLevel`` or ``Logger/setLevel(_:)``.
enum Logger {
    /// Subsystem identifier used for ``os.Logger`` instances.
    static let subsystem = "SwiftyNetwork"

    /// Categories used to group related log statements in Console.app.
    enum Category: String {
        case network
        case cache
        case auth
        case repository
        case security
        case mutation
    }

    /// Atomic storage for the active log level.
    private static let _level = OSAllocatedUnfairLock<LogLevel>(initialState: .warning)

    /// The current log level. Defaults to ``LogLevel/warning``.
    static var level: LogLevel {
        _level.withLock { $0 }
    }

    /// Updates the active log level for the entire package.
    ///
    /// - Parameter newLevel: The new log level to apply.
    static func setLevel(_ newLevel: LogLevel) {
        _level.withLock { $0 = newLevel }
    }

    /// Returns the cached ``os.Logger`` for the given category.
    private static func osLogger(for category: Category) -> os.Logger {
        switch category {
        case .network: return OSLoggers.network
        case .cache: return OSLoggers.cache
        case .auth: return OSLoggers.auth
        case .repository: return OSLoggers.repository
        case .security: return OSLoggers.security
        case .mutation: return OSLoggers.mutation
        }
    }

    /// One lazily created ``os.Logger`` per category, so emitting a message
    /// doesn't allocate a new logger each time.
    private enum OSLoggers {
        static let network = make(.network)
        static let cache = make(.cache)
        static let auth = make(.auth)
        static let repository = make(.repository)
        static let security = make(.security)
        static let mutation = make(.mutation)

        private static func make(_ category: Category) -> os.Logger {
            os.Logger(subsystem: Logger.subsystem, category: category.rawValue)
        }
    }

    // MARK: - Emit

    // Messages are `@autoclosure`s so interpolated strings are only built when
    // the level is enabled; call sites stay `Logger.debug("... \(value)")`.

    static func debug(_ message: @autoclosure () -> String, category: Category = .network) {
        guard level >= .debug else { return }
        let message = message()
        osLogger(for: category).debug("\(message, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String, category: Category = .network) {
        guard level >= .info else { return }
        let message = message()
        osLogger(for: category).info("\(message, privacy: .public)")
    }

    static func warning(_ message: @autoclosure () -> String, category: Category = .network) {
        guard level >= .warning else { return }
        let message = message()
        osLogger(for: category).warning("\(message, privacy: .public)")
    }

    static func error(
        _ message: @autoclosure () -> String,
        error: (any Error)? = nil,
        category: Category = .network
    ) {
        guard level >= .error else { return }
        let message = message()
        if let error {
            let errorDescription = String(describing: error)
            osLogger(for: category).error(
                "\(message, privacy: .public) — \(errorDescription, privacy: .private)")
        } else {
            osLogger(for: category).error("\(message, privacy: .public)")
        }
    }

    // MARK: - URL Helpers

    /// Logs a URL with private sanitization so query strings don't leak in the unified log.
    static func debugURL(_ message: @autoclosure () -> String, url: URL, category: Category = .network) {
        guard level >= .debug else { return }
        let message = message()
        osLogger(for: category).debug("\(message, privacy: .public) \(url.absoluteString, privacy: .private)")
    }
}
