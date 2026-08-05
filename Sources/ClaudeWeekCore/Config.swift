import Foundation

public enum ProviderPreference: String, Codable, Sendable, CaseIterable {
    case official
    case local
    case auto
}

public enum MenuBarStyle: String, Codable, Sendable, CaseIterable {
    case percent
    case compact
}

/// Палитра панели. `system` — исходная, прогнанная через валидатор на
/// дальтонизм и контраст; остальные добавлены, чтобы было чем играть,
/// и держат те же роли цветов.
public enum ThemeKind: String, Codable, Sendable, CaseIterable {
    /// Родная палитра: нейтральный фон, синий план, зелёный факт.
    case system
    /// Глубокий сине-чёрный, как у ночных меню.
    case midnight
    /// Тёплый графит без синевы.
    case graphite
    /// Бумажная: светлая в обеих темах, для светлых рабочих столов.
    case paper
    /// Максимальный контраст: плотные цвета, никакой полупрозрачности.
    case contrast

    public var title: String {
        switch self {
        case .system: "Системная"
        case .midnight: "Полночь"
        case .graphite: "Графит"
        case .paper: "Бумага"
        case .contrast: "Контраст"
        }
    }
}

/// Как подписан момент сброса пятичасовой сессии. Сам момент приходит из
/// ответа сервера и от настройки не зависит — она выбирает только то, каким
/// концом его показать: сколько осталось или когда наступит.
public enum SessionResetDisplay: String, Codable, Sendable, CaseIterable {
    /// «сброс через 1 ч 12 мин» — сколько ещё можно работать.
    case relative
    /// «сброс в 14:35» — момент на часах, удобно сверять с планами на день.
    case absolute
    /// «сброс через 1 ч 12 мин (14:35)» — и то, и другое.
    case both

    public var title: String {
        switch self {
        case .relative: "Сколько осталось"
        case .absolute: "Во сколько сбросится"
        case .both: "И то, и другое"
        }
    }
}

/// Всё, что влияет только на вид и ни на одну цифру.
public struct AppearanceConfig: Codable, Sendable, Equatable {
    public var theme: ThemeKind
    /// Фон панели — материал строки меню (полупрозрачный с размытием).
    /// Выключено — сплошная заливка палитры.
    public var transparentPanel: Bool
    /// Плотность вуали поверх материала, 0…1: 0 — чистый материал строки
    /// меню, 1 — самая плотная вуаль, сквозь которую размытие ещё видно.
    /// Дальше идёт не «почти непрозрачный фон», а выключенная прозрачность:
    /// глухая заливка — это отдельный режим, а не край ползунка.
    public var panelTintOpacity: Double
    /// Скругление углов панели, pt.
    public var cornerRadius: Double
    /// Строка пятичасовой сессии над сутками.
    public var showSession: Bool
    /// Вторая строка футера с прогнозом «кончится в …».
    public var showForecast: Bool
    /// Каким концом подписан сброс сессии.
    public var sessionReset: SessionResetDisplay

    public init(
        theme: ThemeKind = .system,
        transparentPanel: Bool = true,
        panelTintOpacity: Double = 0.18,
        cornerRadius: Double = 12,
        showSession: Bool = true,
        showForecast: Bool = true,
        sessionReset: SessionResetDisplay = .relative
    ) {
        self.theme = theme
        self.transparentPanel = transparentPanel
        self.panelTintOpacity = panelTintOpacity
        self.cornerRadius = cornerRadius
        self.showSession = showSession
        self.showForecast = showForecast
        self.sessionReset = sessionReset
    }

    // Как и в `Config`: каждое поле необязательно. Конфиг, записанный прошлой
    // версией, не знает новых ключей, и падать на них нельзя — иначе одна
    // добавленная настройка сбрасывает человеку все остальные.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceConfig()
        self.init(
            theme: try c.decodeIfPresent(ThemeKind.self, forKey: .theme) ?? d.theme,
            transparentPanel: try c.decodeIfPresent(Bool.self, forKey: .transparentPanel)
                ?? d.transparentPanel,
            panelTintOpacity: try c.decodeIfPresent(Double.self, forKey: .panelTintOpacity)
                ?? d.panelTintOpacity,
            cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius,
            showSession: try c.decodeIfPresent(Bool.self, forKey: .showSession) ?? d.showSession,
            showForecast: try c.decodeIfPresent(Bool.self, forKey: .showForecast) ?? d.showForecast,
            sessionReset: try c.decodeIfPresent(SessionResetDisplay.self, forKey: .sessionReset)
                ?? d.sessionReset
        )
    }

    public func validated() -> AppearanceConfig {
        var a = self
        a.panelTintOpacity = min(max(a.panelTintOpacity, 0), 1)
        a.cornerRadius = min(max(a.cornerRadius, 0), 24)
        return a
    }
}

/// Однократное наблюдение официального процента: по нему подбирается
/// `weeklyBudget` для локальной оценки.
public struct Calibration: Codable, Sendable, Equatable {
    public var observedPercent: Double?
    public var at: Date?

    public init(observedPercent: Double? = nil, at: Date? = nil) {
        self.observedPercent = observedPercent
        self.at = at
    }
}

public struct Thresholds: Codable, Sendable, Equatable {
    /// Во сколько раз факт может превышать план, прежде чем полоса станет
    /// янтарной. 1.0 = сразу за плановой отметкой.
    public var warn: Double
    /// Доля лимита, после которой заголовок краснеет.
    public var critical: Double

    public init(warn: Double = 1.0, critical: Double = 0.9) {
        self.warn = warn
        self.critical = critical
    }
}

public struct Config: Codable, Sendable, Equatable {
    /// 1 = воскресенье … 6 = пятница … 7 = суббота (нумерация Calendar).
    public var resetWeekday: Int
    public var resetHour: Int
    public var resetMinute: Int
    /// Идентификатор таймзоны; пустая строка — системная.
    public var timeZone: String
    /// Секунды между опросами, не меньше `minimumRefreshInterval`.
    public var refreshInterval: TimeInterval
    public var provider: ProviderPreference
    /// Часы, между которыми растёт план. Вне их он стоит: недельный лимит
    /// раскладывается по рабочему времени, а не по астрономическому.
    public var workHours: WorkHours
    public var menuBarStyle: MenuBarStyle
    /// Условная стоимость недели для локального режима; 0 = не откалиброван.
    public var weeklyBudget: Double
    public var calibration: Calibration
    public var thresholds: Thresholds
    /// Вид панели; на цифры не влияет.
    public var appearance: AppearanceConfig

    public static let minimumRefreshInterval: TimeInterval = 30

    /// Сброс недельного лимита приходит в 12:00 UTC — в 15:00 по Москве и в
    /// 16:00 здесь, в UTC+4. Это догадка на случай, когда сервер молчит: в
    /// обычной жизни момент берётся из `resets_at` официального ответа. Час
    /// привязан к `timeZone` ниже — сменив её, поправьте и его.
    public static let `default` = Config(
        resetWeekday: 6,
        resetHour: 16,
        resetMinute: 0,
        timeZone: "Europe/Saratov",
        refreshInterval: 300,
        provider: .auto,
        workHours: WorkHours.default,
        menuBarStyle: .percent,
        weeklyBudget: 0,
        calibration: Calibration(),
        thresholds: Thresholds(),
        appearance: AppearanceConfig()
    )

    public init(
        resetWeekday: Int,
        resetHour: Int,
        resetMinute: Int,
        timeZone: String,
        refreshInterval: TimeInterval,
        provider: ProviderPreference,
        workHours: WorkHours = WorkHours.default,
        menuBarStyle: MenuBarStyle,
        weeklyBudget: Double,
        calibration: Calibration,
        thresholds: Thresholds,
        appearance: AppearanceConfig = AppearanceConfig()
    ) {
        self.resetWeekday = resetWeekday
        self.resetHour = resetHour
        self.resetMinute = resetMinute
        self.timeZone = timeZone
        self.refreshInterval = refreshInterval
        self.provider = provider
        self.workHours = workHours
        self.menuBarStyle = menuBarStyle
        self.weeklyBudget = weeklyBudget
        self.calibration = calibration
        self.thresholds = thresholds
        self.appearance = appearance
    }

    // Каждое поле необязательно: незнакомый или неполный конфиг не должен
    // ронять приложение — недостающее берётся из дефолтов.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        self.init(
            resetWeekday: try c.decodeIfPresent(Int.self, forKey: .resetWeekday) ?? d.resetWeekday,
            resetHour: try c.decodeIfPresent(Int.self, forKey: .resetHour) ?? d.resetHour,
            resetMinute: try c.decodeIfPresent(Int.self, forKey: .resetMinute) ?? d.resetMinute,
            timeZone: try c.decodeIfPresent(String.self, forKey: .timeZone) ?? d.timeZone,
            refreshInterval: try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? d.refreshInterval,
            provider: try c.decodeIfPresent(ProviderPreference.self, forKey: .provider) ?? d.provider,
            workHours: try c.decodeIfPresent(WorkHours.self, forKey: .workHours) ?? d.workHours,
            menuBarStyle: try c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? d.menuBarStyle,
            weeklyBudget: try c.decodeIfPresent(Double.self, forKey: .weeklyBudget) ?? d.weeklyBudget,
            calibration: try c.decodeIfPresent(Calibration.self, forKey: .calibration) ?? d.calibration,
            thresholds: try c.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? d.thresholds,
            appearance: try c.decodeIfPresent(AppearanceConfig.self, forKey: .appearance) ?? d.appearance
        )
    }

    /// Приводит значения к допустимым: кривой конфиг чинится, а не отвергается.
    public func validated() -> Config {
        var c = self
        if !(1...7).contains(c.resetWeekday) {
            Log.warn("resetWeekday=\(c.resetWeekday) вне 1…7, беру \(Config.default.resetWeekday)")
            c.resetWeekday = Config.default.resetWeekday
        }
        if !(0...23).contains(c.resetHour) {
            Log.warn("resetHour=\(c.resetHour) вне 0…23, беру \(Config.default.resetHour)")
            c.resetHour = Config.default.resetHour
        }
        if !(0...59).contains(c.resetMinute) {
            Log.warn("resetMinute=\(c.resetMinute) вне 0…59, беру 0")
            c.resetMinute = 0
        }
        if !c.timeZone.isEmpty && TimeZone(identifier: c.timeZone) == nil {
            Log.warn("неизвестная таймзона «\(c.timeZone)», беру системную")
            c.timeZone = ""
        }
        if c.refreshInterval < Config.minimumRefreshInterval {
            Log.warn("refreshInterval=\(c.refreshInterval) меньше минимума, беру \(Config.minimumRefreshInterval)")
            c.refreshInterval = Config.minimumRefreshInterval
        }
        c.workHours = c.workHours.validated()
        if c.weeklyBudget < 0 { c.weeklyBudget = 0 }
        if c.thresholds.warn <= 0 { c.thresholds.warn = Thresholds().warn }
        if !(0...1).contains(c.thresholds.critical) { c.thresholds.critical = Thresholds().critical }
        c.appearance = c.appearance.validated()
        return c
    }

    public var resolvedTimeZone: TimeZone {
        if timeZone.isEmpty { return TimeZone.current }
        return TimeZone(identifier: timeZone) ?? TimeZone.current
    }

    public var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = resolvedTimeZone
        cal.locale = Locale(identifier: "ru_RU")
        cal.firstWeekday = 2
        return cal
    }
}

// MARK: - Файл конфигурации

public enum ConfigStore {
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/claude-week", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    /// Читает конфиг; отсутствие файла — норма, битый файл — предупреждение
    /// и дефолты (терять строку меню из-за опечатки в JSON незачем).
    public static func load(from url: URL = ConfigStore.fileURL) -> Config {
        guard let data = try? Data(contentsOf: url) else {
            return Config.default.validated()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // JSON5 разрешает комментарии — в примере конфига они есть.
            decoder.allowsJSON5 = true
            return try decoder.decode(Config.self, from: data).validated()
        } catch {
            Log.error("не разобрал \(url.path): \(error). Беру значения по умолчанию")
            return Config.default.validated()
        }
    }

    public static func save(_ config: Config, to url: URL = ConfigStore.fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
