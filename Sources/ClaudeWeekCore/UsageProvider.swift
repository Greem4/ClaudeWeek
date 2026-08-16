import Foundation

public protocol UsageProvider: Sendable {
    nonisolated var kind: SourceKind { get }
    func fetch() async throws -> UsageSnapshot
}

public enum UsageError: Error, LocalizedError {
    /// Локальный бюджет не подобран — процент считать не из чего.
    case notCalibrated
    case unauthorized
    case network(Bilingual)
    case decoding(Bilingual)
    case unavailable(Bilingual)

    /// Русский текст: он же уходит в лог, который читают при разборе поломки.
    public var errorDescription: String? { message(.ru) }

    /// То же на языке интерфейса — эти строки доходят до панели и до кнопки
    /// «Проверить сейчас», а не только до лога.
    public func message(_ lang: Lang) -> String {
        let l = L10n(lang)
        switch self {
        case .notCalibrated:
            return l.pick("локальная оценка не откалибрована: укажите weeklyBudget или calibration в конфиге",
                          "the local estimate is not calibrated: set weeklyBudget or calibration in the config")
        case .unauthorized:
            return l.pick("нужна авторизация в Claude Code", "Claude Code authorisation is required")
        case .network(let text):
            return l.pick("сеть недоступна: \(text.text(lang))", "network unavailable: \(text.text(lang))")
        case .decoding(let text):
            return l.pick("не разобрал ответ: \(text.text(lang))",
                          "could not parse the reply: \(text.text(lang))")
        case .unavailable(let text):
            return l.pick("источник недоступен: \(text.text(lang))",
                          "source unavailable: \(text.text(lang))")
        }
    }
}
