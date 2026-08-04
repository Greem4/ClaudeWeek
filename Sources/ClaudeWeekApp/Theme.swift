import AppKit
import SwiftUI
import ClaudeWeekCore

/// Палитра и метрики панели. Цвета прогнаны через валидатор на разделимость
/// при дальтонизме и контраст к фону; менять их по вкусу нельзя — сначала
/// перепроверить пары «факт ↔ вылет» и «план ↔ трек» (см. §5.2 плана).
enum Theme {
    // MARK: Цвета

    /// Трек — то, что за пределами плана этого дня.
    static let track = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)
    /// Остаток плана: приглушённый синий, фон под факт.
    static let plan = dynamic(light: 0x6DA7EC, dark: 0x3987E5)
    /// Факт в пределах плана.
    static let good = Color(hex: 0x0CA30C)
    /// Часть факта, вышедшая за план.
    static let warning = Color(hex: 0xFAB219)
    /// Лимит на исходе или исчерпан — только заголовок и иконка, не заливка:
    /// красный и зелёный неразличимы при дейтеранопии.
    static let critical = Color(hex: 0xD03B3B)

    static let panelBackground = dynamic(light: 0xFCFCFB, dark: 0x1A1A19)
    static let primaryText = dynamic(light: 0x0B0B0B, dark: 0xFFFFFF)
    static let secondaryText = dynamic(light: 0x52514E, dark: 0xC3C2B7)
    static let separator = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)

    // MARK: Метрики

    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 16
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
    static let valueFont = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let footerFont = Font.system(size: 11).monospacedDigit()
    /// Заголовочные подписи справа: в 288 pt рядом с «ЛИМИТ НЕДЕЛИ»
    /// одиннадцатый кегль уже не помещается.
    static let captionFont = Font.system(size: 10).monospacedDigit()

    /// Цвет числа и полоски в строке меню зависит от состояния лимита.
    static func accent(for state: LimitState) -> Color {
        switch state {
        case .onTrack: primaryText
        case .overPlan: warning
        case .critical, .exhausted: critical
        }
    }

    // MARK: Служебное

    /// Тема следует системной и переключается на лету: цвет разрешается
    /// в момент отрисовки, а не один раз при запуске.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
