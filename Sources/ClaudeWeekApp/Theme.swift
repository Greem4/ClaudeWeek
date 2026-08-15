import AppKit
import SwiftUI
import ClaudeWeekCore

/// Цвет, зависящий от темы системы. Хранится числами, а не готовым NSColor:
/// так палитра остаётся `Sendable`-значением, которое можно положить в
/// окружение SwiftUI и сравнить на равенство.
struct Ink: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32
    let lightAlpha: CGFloat
    let darkAlpha: CGFloat

    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.light = light
        self.dark = dark
        self.lightAlpha = lightAlpha
        self.darkAlpha = darkAlpha
    }

    /// Один и тот же цвет в обеих темах — так заданы статусные цвета.
    init(_ hex: UInt32, alpha: CGFloat = 1) {
        self.init(light: hex, dark: hex, lightAlpha: alpha, darkAlpha: alpha)
    }

    /// Разрешается в момент отрисовки, поэтому переключение темы системы
    /// подхватывается на лету, без перезапуска.
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// Материал под панелью, когда включена прозрачность. Список ровно из того,
/// что берут палитры: материал — часть темы, и незанятый case означал бы
/// не «про запас», а «есть вариант, которого никто не видел».
enum PanelMaterial: String, Sendable, Equatable {
    case menu
    case popover
    case sidebar

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .menu: .menu
        case .popover: .popover
        case .sidebar: .sidebar
        }
    }
}

/// Полный набор цветов панели и иконки. Роли фиксированы: меняются оттенки,
/// а смысл — трек, план, факт, вылет — остаётся тем же.
struct Palette: Sendable, Equatable {
    /// Трек — то, что за пределами плана этого дня.
    let track: Ink
    /// Остаток плана: фон под факт.
    let plan: Ink
    /// Факт в пределах плана.
    let good: Ink
    /// Часть факта, вышедшая за план.
    let warning: Ink
    /// Лимит на исходе или исчерпан — только заголовок и иконка, не заливка.
    let critical: Ink
    /// Сплошной фон панели: когда прозрачность выключена и в `--screenshot`.
    let panelBackground: Ink
    /// Цвет вуали поверх материала; её плотность задаётся настройкой.
    let panelTint: Ink
    let primaryText: Ink
    let secondaryText: Ink
    let separator: Ink
    /// Волосяная обводка по контуру панели.
    let border: Ink
    let material: PanelMaterial

    /// Родная палитра. Цвета прогнаны через валидатор на разделимость при
    /// дальтонизме и контраст к фону; менять их по вкусу нельзя — сначала
    /// перепроверить пары «факт ↔ вылет» и «план ↔ трек» (см. §5.2 плана).
    /// Остальные палитры валидатором не проверялись: это игровая площадка.
    static let system = Palette(
        track: Ink(light: 0xE1E0D9, dark: 0x2C2C2A),
        plan: Ink(light: 0x6DA7EC, dark: 0x3987E5),
        good: Ink(0x0CA30C),
        warning: Ink(0xFAB219),
        critical: Ink(0xD03B3B),
        panelBackground: Ink(light: 0xFCFCFB, dark: 0x1A1A19),
        panelTint: Ink(light: 0xFFFFFF, dark: 0x000000),
        // Плотности системных `labelColor` и `secondaryLabelColor`: на
        // материале меню текст мешается с фоном ровно так же, как в пунктах
        // соседей по строке меню, — чистый белый рядом с ними выглядит ярче
        // системного. Вторичный на светлом фоне взят чуть плотнее системных
        // 0.55: те дают 4.55:1, впритык к порогу, а так контраст сравнивается
        // с тёмной темой — 6.0:1 против 5.9:1.
        primaryText: Ink(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.85),
        secondaryText: Ink(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.55),
        separator: Ink(light: 0xE1E0D9, dark: 0x2C2C2A),
        border: Ink(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.13),
        material: .menu
    )

    /// Сине-чёрная, как ночные меню.
    static let midnight = Palette(
        track: Ink(light: 0xD8DEEA, dark: 0x1C2233),
        plan: Ink(light: 0x5B87E8, dark: 0x4C7DF0),
        good: Ink(0x22C55E),
        warning: Ink(0xF59E0B),
        critical: Ink(0xEF4444),
        panelBackground: Ink(light: 0xF4F6FB, dark: 0x0B1020),
        panelTint: Ink(light: 0xE8EDF8, dark: 0x050914),
        primaryText: Ink(light: 0x0A0F1C, dark: 0xF2F5FC),
        secondaryText: Ink(light: 0x4A5468, dark: 0xA9B4CC),
        separator: Ink(light: 0xD8DEEA, dark: 0x1C2233),
        border: Ink(light: 0x0A0F1C, dark: 0x8FA6D8, lightAlpha: 0.12, darkAlpha: 0.18),
        material: .menu
    )

    /// Тёплый графит без синевы в фоне.
    static let graphite = Palette(
        track: Ink(light: 0xDEDBD3, dark: 0x2E2C29),
        plan: Ink(light: 0x8A93A3, dark: 0x707C90),
        good: Ink(0x3FA34D),
        warning: Ink(0xE0A008),
        critical: Ink(0xCC4B4B),
        panelBackground: Ink(light: 0xF6F4EF, dark: 0x1C1B19),
        panelTint: Ink(light: 0xFFFDF8, dark: 0x0D0C0B),
        primaryText: Ink(light: 0x1A1917, dark: 0xF5F3EF),
        secondaryText: Ink(light: 0x5C574F, dark: 0xB7B2A8),
        separator: Ink(light: 0xDEDBD3, dark: 0x2E2C29),
        border: Ink(light: 0x1A1917, dark: 0xF5F3EF, lightAlpha: 0.12, darkAlpha: 0.10),
        material: .sidebar
    )

    /// Бумажная: светлая независимо от темы системы.
    static let paper = Palette(
        track: Ink(0xE6E2D8),
        plan: Ink(0x5B8DD6),
        good: Ink(0x2E8B2E),
        warning: Ink(0xD08A00),
        critical: Ink(0xC23B3B),
        panelBackground: Ink(0xF7F5EF),
        panelTint: Ink(0xFFFFFF),
        primaryText: Ink(0x141312),
        secondaryText: Ink(0x55524B),
        separator: Ink(0xE6E2D8),
        border: Ink(0x141312, alpha: 0.14),
        material: .popover
    )

    /// Максимальный контраст: плотные цвета, фон почти чёрный или почти белый.
    static let contrast = Palette(
        track: Ink(light: 0xC9C9C9, dark: 0x3A3A3A),
        plan: Ink(light: 0x1E4FA8, dark: 0x4C8DFF),
        good: Ink(light: 0x006E00, dark: 0x00C000),
        warning: Ink(light: 0xA35C00, dark: 0xFFB000),
        critical: Ink(light: 0xB3000F, dark: 0xFF453A),
        panelBackground: Ink(light: 0xFFFFFF, dark: 0x000000),
        panelTint: Ink(light: 0xFFFFFF, dark: 0x000000),
        primaryText: Ink(light: 0x000000, dark: 0xFFFFFF),
        secondaryText: Ink(light: 0x2B2B2B, dark: 0xE0E0E0),
        separator: Ink(light: 0xB0B0B0, dark: 0x4A4A4A),
        border: Ink(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.35, darkAlpha: 0.35),
        material: .menu
    )
}

extension ThemeKind {
    var palette: Palette {
        switch self {
        case .system: .system
        case .midnight: .midnight
        case .graphite: .graphite
        case .paper: .paper
        case .contrast: .contrast
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.system
}

extension EnvironmentValues {
    /// Палитра текущей темы. Ставится один раз в корне панели, дальше её
    /// читают все строки — так смена темы в настройках перекрашивает всё
    /// разом, без передачи цвета через каждый инициализатор.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Метрики и шрифты панели. Цвета живут в `Palette`.
enum Theme {
    // MARK: Метрики

    /// Под кегль меню: строка «⚠ 70 / 64 %» рядом с подписью дня и полосой
    /// требует места, а заголовок держит две подписи справа от себя. Сводка
    /// футера в одну строку — тот же предел.
    static let panelWidth: CGFloat = 380
    /// Поля как у пунктов системного меню.
    static let panelPadding: CGFloat = 14
    /// Отступ от края экрана, когда пункт стоит у самого угла.
    static let panelScreenMargin: CGFloat = 8
    static let rowSpacing: CGFloat = 10
    static let barHeight: CGFloat = 9
    /// Вторичный канал кодирования: держит границу читаемой там, где цвета
    /// сливаются (тританопия в тёмной теме даёт ΔE 5.1 на паре факт ↔ вылет).
    static let overspendGap: CGFloat = 2
    static let dayLabelWidth: CGFloat = 30
    /// Колонка имени модели в разбивке. Шире дневной: «ПН» и «Sonnet» —
    /// подписи разной длины, а мерить приходится так же по самой длинной,
    /// потому что кегль растёт вместе с системным. Имена длиннее (незнакомая
    /// модель зовётся полным именем) обрезаются многоточием — расползаться
    /// строке нельзя, за ней поедет вся панель.
    static let modelLabelWidth: CGFloat = textWidth("Sonnet").rounded(.up) + 2
    /// Зазор между значком перерасхода и самим числом.
    static let valueGap: CGFloat = 3
    /// Колонка значений справа. Числом её задавать нельзя: кегль берётся у
    /// системного меню и в универсальном доступе растёт вместе с ним, а самая
    /// длинная строка колонки — «⚠ 100 / 100 %» — не влезала в прежние 96 pt
    /// и на исчерпанной неделе рвалась на два ряда, унося за собой высоту
    /// строки. Поэтому ширину меряем по ней же, а полоса рядом отдаёт эти
    /// пункты: её длина и так условная, а число обязано читаться целиком.
    /// Пункт запаса — на то, что SwiftUI размечает текст чуть иначе AppKit.
    static let valueWidth: CGFloat =
        (textWidth("⚠") + valueGap + textWidth("100 / 100 %")).rounded(.up) + 2
    static let fillAnimation: TimeInterval = 0.35
    /// Кружок источника — вровень с полосой, рядом с которой стоит.
    static let sourceDotSize: CGFloat = 9
    /// Контур у него заметно толще волосяного: на кружке в 9 pt тонкая линия
    /// на прозрачном фоне читается как грязь, а не как «не залито».
    static let sourceDotStroke: CGFloat = 1.5
    /// Насколько зона клика шире самого кружка. В 9 pt мышью не попасть, а
    /// разметку расширение не трогает: поля тут же снимаются отрицательными.
    static let sourceDotHitPadding: CGFloat = 7
    /// Сколько текст источника держится на месте полосы, прежде чем строка
    /// вернётся к обычному виду. Хватает прочесть отказ в две строки; дольше
    /// панель стояла бы без полосы, ради которой её и открыли.
    static let sourceTextDuration: TimeInterval = 4

    /// Потолок вуали поверх материала. Единица шкалы — не «непрозрачный фон»:
    /// плотная вуаль съедает размытие, и прозрачный режим переставал
    /// отличаться от сплошного ничем, кроме оттенка. 0.55 — предел, за
    /// которым материала уже не видно.
    static let maxPanelTint: Double = 0.55

    // MARK: Шрифты

    /// Кегль пунктов системного меню (14 pt на обычных настройках). Берём у
    /// системы, а не числом: панель висит под строкой меню и должна читаться
    /// как её продолжение, а с крупным текстом в универсальном доступе кегль
    /// меняется. Спрашиваем один раз за запуск — смена системной настройки
    /// доедет до панели после перезапуска приложения.
    static let menuFontSize = NSFont.menuFont(ofSize: 0).pointSize
    /// Сноски — на два кегля мельче основного текста, как в меню.
    static let captionFontSize = menuFontSize - 2

    static let titleFont = Font.system(size: menuFontSize, weight: .semibold).monospacedDigit()
    static let dayFont = Font.system(size: menuFontSize).monospacedDigit()
    /// Подпись текущих суток: тот же кегль, но полужирная. Одного цвета ей не
    /// хватало — в ряду из семи одинаковых подписей разница между основным и
    /// вторичным текстом не ловится взглядом, и день приходилось искать.
    static let todayFont = Font.system(size: menuFontSize, weight: .semibold).monospacedDigit()
    /// Кнопки футера: глифы ⚙ и ⟳ в кегле сноски становятся неприцельными.
    static let actionFont = Font.system(size: menuFontSize)
    /// Сводка футера — самая мелкая строка панели: в кегле сноски «осталось
    /// 42 % · сброс через 3 дн 18 ч» вместе с прогнозом рвётся на два ряда.
    static let footerFont = Font.system(size: menuFontSize - 3).monospacedDigit()
    static let captionFont = Font.system(size: captionFontSize).monospacedDigit()

    /// Ширина строки в шрифте суточных полос: `Font.system(size:)` с
    /// `.monospacedDigit()` — это он же, только со стороны SwiftUI.
    private static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: menuFontSize, weight: .regular)
        ]).width
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
