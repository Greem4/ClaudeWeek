import Foundation

/// Логи идут в stderr: приложение живёт под LaunchAgent, и его stderr
/// перенаправляется в файл (см. scripts/install.sh).
public enum Log {
    public enum Level: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warn = 2
        case error = 3

        var label: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warn: "WARN"
            case .error: "ERROR"
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    nonisolated(unsafe) public static var minimumLevel: Level = .info

    public static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { write(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private static func write(_ level: Level, _ message: String) {
        guard level >= minimumLevel else { return }
        let stamp = Date().formatted(.iso8601)
        FileHandle.standardError.write(Data("\(stamp) [\(level.label)] \(message)\n".utf8))
    }
}
