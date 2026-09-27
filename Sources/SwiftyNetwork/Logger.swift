import Foundation
import SwiftCommons

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

// MARK: - Level Bridging

extension LogLevel {
    /// The equivalent ``LibraryLogger/Level`` used by the underlying logger.
    var libraryLevel: LibraryLogger.Level {
        switch self {
        case .off: .off
        case .error: .error
        case .warning: .warning
        case .info: .info
        case .debug: .debug
        }
    }

    init(_ level: LibraryLogger.Level) {
        switch level {
        case .off: self = .off
        case .error: self = .error
        case .warning: self = .warning
        case .info: self = .info
        case .debug: self = .debug
        }
    }
}

// MARK: - Internal Logger

/// Internal logging facade that routes SwiftyNetwork messages through
/// SwiftCommons' ``LibraryLogger``.
///
/// Messages are public and only built when their level is enabled; attached
/// errors log their type, domain, and code publicly and their description
/// privately. The active level is process-wide and can be changed via
/// ``NetworkClientConfiguration/logLevel`` or ``Logger/setLevel(_:)``.
enum Logger {
    /// Subsystem identifier used for unified logging.
    static let subsystem = "SwiftyNetwork"

    /// Categories used to group related log statements in Console.app.
    enum Category: String, CaseIterable {
        case network
        case cache
        case auth
        case repository
        case security
        case mutation
    }

    private static let library = LibraryLogger(subsystem: subsystem, defaultLevel: .warning)

    private static let handles: [Category: LibraryLogger.Category] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, library.category($0.rawValue)) }
    )

    /// The current log level. Defaults to ``LogLevel/warning``.
    static var level: LogLevel {
        LogLevel(library.level)
    }

    /// Updates the active log level for the entire package.
    ///
    /// - Parameter newLevel: The new log level to apply.
    static func setLevel(_ newLevel: LogLevel) {
        library.setLevel(newLevel.libraryLevel)
    }

    private static func handle(for category: Category) -> LibraryLogger.Category {
        handles[category] ?? library.category(category.rawValue)
    }

    // MARK: - Emit

    static func debug(_ message: @autoclosure () -> String, category: Category = .network) {
        handle(for: category).debug(message())
    }

    static func info(_ message: @autoclosure () -> String, category: Category = .network) {
        handle(for: category).info(message())
    }

    static func warning(_ message: @autoclosure () -> String, category: Category = .network) {
        handle(for: category).warning(message())
    }

    static func error(
        _ message: @autoclosure () -> String,
        error: (any Error)? = nil,
        category: Category = .network
    ) {
        handle(for: category).error(message(), error: error)
    }

    // MARK: - URL Helpers

    /// Logs a URL with private sanitization so query strings don't leak in the unified log.
    static func debugURL(_ message: @autoclosure () -> String, url: URL, category: Category = .network) {
        handle(for: category).debug(message(), url: url)
    }
}
