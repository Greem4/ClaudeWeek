import Foundation

public protocol UsageProvider: Sendable {
    nonisolated var kind: SourceKind { get }
    func fetch() async throws -> UsageSnapshot
}

public enum UsageError: Error, LocalizedError {
    /// Локальный бюджет не подобран — процент считать не из чего.
    case notCalibrated
    case unauthorized
    case network(String)
    case decoding(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notCalibrated:
            "локальная оценка не откалибрована: укажите weeklyBudget или calibration в конфиге"
        case .unauthorized:
            "нужна авторизация в Claude Code"
        case .network(let text):
            "сеть недоступна: \(text)"
        case .decoding(let text):
            "не разобрал ответ: \(text)"
        case .unavailable(let text):
            "источник недоступен: \(text)"
        }
    }
}
