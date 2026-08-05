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

/// Материал под панелью, когда включена прозрачность.
enum PanelMaterial: String, Sendable, Equatable {
    case menu
    case popover
    case hud
    case sidebar

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .menu: .menu
        case .popover: .popover
        case .hud: .hudWindow
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
        primaryText: Ink(light: 0x0B0B0B, dark: 0xFFFFFF),
        secondaryText: Ink(light: 0x52514E, dark: 0xC3C2B7),
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

    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 16
    /// Отступ от края экрана, когда пункт стоит у самого угла.
    static let panelScreenMargin: CGFloat = 8
    static let rowSpacing: CGFloat = 10
    static let barHeight: CGFloat = 8
    /// Вторичный канал кодирования: держит границу читаемой там, где цвета
    /// сливаются (тританопия в тёмной теме даёт ΔE 5.1 на паре факт ↔ вылет).
    static let overspendGap: CGFloat = 2
    static let dayLabelWidth: CGFloat = 26
    static let valueWidth: CGFloat = 74
    static let fillAnimation: TimeInterval = 0.35

    // MARK: Шрифты

    static let titleFont = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let dayFont = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let footerFont = Font.system(size: 11).monospacedDigit()
    /// Заголовочные подписи справа: в 288 pt рядом с «ЛИМИТ НЕДЕЛИ»
    /// одиннадцатый кегль уже не помещается.
    static let captionFont = Font.system(size: 10).monospacedDigit()
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
