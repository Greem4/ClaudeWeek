import AppKit
import ClaudeWeekCore

/// Иконка в строке меню: полоса недели, под ней — процент. Те же три цвета,
/// что и в панели. Два этажа вместо «полоска, а рядом текст» экономят почти
/// половину ширины пункта: ~28 pt против ~57 pt.
enum MenuBarBar {
    /// Высота картинки. Строка меню — 24 pt, 16 оставляет поля сверху и снизу.
    static let height: CGFloat = 16
    /// Ниже полоса становится нечитаемо короткой, даже если подпись узкая.
    static let minimumWidth: CGFloat = 24

    private static let barHeight: CGFloat = 3
    /// Просвет между полосой и цифрами.
    private static let gap: CGFloat = 1
    /// Девятый кегль — предел, на котором цифры в строке меню ещё читаются.
    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    }

    /// `title` = nil — режим `compact`: одна полоса, без числа.
    ///
    /// `colorize` — тумблер окраски по порогам. Выключенный гасит и цифру, и
    /// саму заливку: раньше он подменял состояние на `.normal`, а `.normal`
    /// у полосы зелёный — выходил не нейтральный значок, а всегда зелёный.
    static func image(
        usedPercent: Double,
        planPercent: Double,
        state: LimitState,
        title: String?,
        colorize: Bool = true,
        palette: Palette = .system
    ) -> NSImage {
        let label = title.map { attributed($0, state: state, colorize: colorize, palette: palette) }
        let labelSize = label?.size() ?? .zero
        let width = max(minimumWidth, ceil(labelSize.width) + 2)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            // Содержимое центрируем по высоте целиком, а не полосу и цифры
            // по отдельности — иначе иконка «висит» выше соседей в строке.
            let content = barHeight + (label == nil ? 0 : gap + labelSize.height)
            let top = (rect.height + content) / 2

            drawBar(
                in: NSRect(x: 0, y: top - barHeight, width: rect.width, height: barHeight),
                usedPercent: usedPercent, planPercent: planPercent,
                state: state, colorize: colorize, palette: palette
            )

            if let label {
                label.draw(at: NSPoint(x: (rect.width - labelSize.width) / 2, y: top - content))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Пустая иконка, пока данных нет.
    static func placeholder(title: String?, palette: Palette = .system) -> NSImage {
        image(usedPercent: 0, planPercent: 0, state: .normal, title: title, palette: palette)
    }

    private static func drawBar(
        in rect: NSRect,
        usedPercent: Double,
        planPercent: Double,
        state: LimitState,
        colorize: Bool,
        palette: Palette
    ) {
        let radius = rect.height / 2

        palette.track.nsColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        // План остаётся ориентиром «где я по графику», но цвет ему больше не
        // подчиняется: перерасход в понедельник — это ещё не тревога.
        let planWidth = rect.width * clamp(planPercent)
        palette.plan.nsColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: planWidth, height: rect.height),
            xRadius: radius, yRadius: radius
        ).fill()

        let usedWidth = rect.width * clamp(usedPercent)
        guard usedWidth > 0 else { return }
        fillColor(for: state, colorize: colorize, palette: palette).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: usedWidth, height: rect.height),
            xRadius: radius, yRadius: radius
        ).fill()
    }

    /// Цвет заливки: те же пороги, что у цифр, но спокойное состояние —
    /// зелёное, а не «цвет текста»: полоса в 3 pt нейтральным цветом сливается
    /// с треком. Выключенная окраска — исключение: там нейтральный цвет и
    /// нужен, а `labelColor` от трека отличается заметно.
    private static func fillColor(
        for state: LimitState,
        colorize: Bool,
        palette: Palette
    ) -> NSColor {
        guard colorize else { return .labelColor }
        return switch state {
        case .normal: palette.good.nsColor
        case .warning: palette.warning.nsColor
        case .critical, .exhausted: palette.critical.nsColor
        }
    }

    private static func attributed(
        _ title: String,
        state: LimitState,
        colorize: Bool,
        palette: Palette
    ) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: textColor(for: state, colorize: colorize, palette: palette),
            ]
        )
    }

    /// Цвет цифр. `labelColor` динамический — он разрешается в момент
    /// отрисовки, поэтому подходит и к тёмной, и к светлой строке меню.
    private static func textColor(
        for state: LimitState,
        colorize: Bool,
        palette: Palette
    ) -> NSColor {
        MenuBarRing.color(for: state, colorize: colorize, palette: palette)
    }

    private static func clamp(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }
}
