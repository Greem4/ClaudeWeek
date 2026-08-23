import Foundation

/// Язык интерфейса, как он записан в конфиге.
///
/// `system` — следовать за системой; это значение по умолчанию, и оно же
/// достаётся конфигам, заведённым до того, как язык вообще появился. Явные
/// `ru` и `en` перекрывают систему: у человека может быть английская macOS и
/// желание видеть программу по-русски.
public enum Language: String, Codable, Sendable, CaseIterable {
    case system
    case ru
    case en

    /// Что показывать в списке настроек. Названия самих языков не переводятся —
    /// «Русский» ищут глазами по-русски, а не по слову «Russian», и так же
    /// устроены системные настройки macOS. Переводится только «системный».
    public func title(_ lang: Lang) -> String {
        switch self {
        case .system: lang == .ru ? "Как в системе" : "System"
        case .ru: "Русский"
        case .en: "English"
        }
    }

    /// Язык, на котором в итоге говорит интерфейс.
    public var resolved: Lang {
        switch self {
        case .ru: .ru
        case .en: .en
        case .system: Language.systemLanguage
        }
    }

    /// Язык системы, сведённый к двум: всё русское — русское, остальное —
    /// английское. Третьей ветки нет намеренно: языков в программе два, и
    /// притворяться, что их больше, незачем.
    static var systemLanguage: Lang {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("ru") ? .ru : .en
    }
}

/// Язык, на котором рисуется интерфейс. Отличается от `Language` тем, что
/// `system` здесь уже разрешён в конкретный язык.
public enum Lang: String, Sendable, CaseIterable {
    case ru
    case en
}

/// Строки интерфейса — обе версии рядом, в одном месте.
///
/// Почему не `.strings` в ресурсах: `scripts/make-app.sh` кладёт в бандл один
/// бинарь и ресурсы SwiftPM туда не переносит — переводы работали бы в
/// `swift run` и молча пропадали в собранном приложении. Разбор обоих путей —
/// в [docs/L10N.md](../../docs/L10N.md).
///
/// Пара `pick(ru, en)` вместо словаря с ключами: компилятор не даёт объявить
/// строку без перевода, а рядом стоящие версии видно одним взглядом — при
/// правке русского английский не остаётся жить своей жизнью.
public struct L10n: Sendable, Equatable {
    public let lang: Lang

    public init(_ lang: Lang) { self.lang = lang }
    public init(_ language: Language) { self.lang = language.resolved }

    /// Русская версия слева, английская справа.
    ///
    /// Пары стоят прямо в местах использования, а не собраны в один словарь с
    /// ключами: ключ — это третье имя для той же строки, которое надо
    /// придумать, найти при правке и не перепутать. Рядом стоящие версии
    /// правятся вместе, и компилятор не даёт написать одну без другой.
    public func pick(_ ru: String, _ en: String) -> String { lang == .ru ? ru : en }

    /// Множественное число: русскому нужны три формы, английскому две.
    /// Число подставляется само — «2 дня», «2 days».
    func plural(_ count: Int, _ ruOne: String, _ ruFew: String, _ ruMany: String,
                _ enOne: String, _ enMany: String) -> String {
        let word: String
        if lang == .ru {
            let tail = count % 100
            let last = count % 10
            if (11...14).contains(tail) {
                word = ruMany
            } else if last == 1 {
                word = ruOne
            } else if (2...4).contains(last) {
                word = ruFew
            } else {
                word = ruMany
            }
        } else {
            word = count == 1 ? enOne : enMany
        }
        return "\(count) \(word)"
    }
}

// MARK: - Общие

extension L10n {
    public var languageTitle: String { pick("Язык", "Language") }
}

/// Строка, у которой есть обе версии сразу.
///
/// Нужна там, где текст рождается глубоко в ядре — отказ Keychain, сорванная
/// установка, — а показывается наверху, в панели или в окне: язык в точке
/// появления ещё неизвестен, а тащить его туда параметром значит протянуть
/// его через полдюжины слоёв, которым он больше нигде не нужен.
///
/// Литерал остаётся литералом: строка без перевода читается одинаково на обоих
/// языках. Так подробности вроде системного сообщения или пути к файлу
/// подставляются как есть, не заводя себе второй копии.
public struct Bilingual: Sendable, Equatable, ExpressibleByStringLiteral,
                         ExpressibleByStringInterpolation, CustomStringConvertible {
    let ru: String
    let en: String

    public init(_ ru: String, _ en: String) {
        self.ru = ru
        self.en = en
    }

    public init(stringLiteral value: String) {
        self.ru = value
        self.en = value
    }

    public func text(_ lang: Lang) -> String { lang == .ru ? ru : en }

    /// Русский — тот же выбор, что и у `errorDescription`: в лог идёт язык,
    /// на котором написан весь остальной лог.
    public var description: String { ru }
}
