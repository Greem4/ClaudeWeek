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
    static func image(
        usedPercent: Double,
        planPercent: Double,
        state: LimitState,
        title: String?,
        palette: Palette = .system
    ) -> NSImage {
        let label = title.map { attributed($0, state: state, palette: palette) }
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
                state: state, palette: palette
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
        image(usedPercent: 0, planPercent: 0, state: .onTrack, title: title, palette: palette)
    }

    private static func drawBar(
        in rect: NSRect,
        usedPercent: Double,
        planPercent: Double,
        state: LimitState,
        palette: Palette
    ) {
        let radius = rect.height / 2

        palette.track.nsColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let planWidth = rect.width * clamp(planPercent)
        palette.plan.nsColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: planWidth, height: rect.height),
            xRadius: radius, yRadius: radius
        ).fill()

        let usedWidth = rect.width * clamp(usedPercent)
        palette.good.nsColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX, y: rect.minY,
                width: min(usedWidth, planWidth), height: rect.height
            ),
            xRadius: radius, yRadius: radius
        ).fill()

        if usedWidth > planWidth {
            // Тот же двухпиксельный зазор, что и в панели.
            let start = planWidth + 2
            (state == .exhausted ? palette.critical : palette.warning).nsColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: rect.minX + start, y: rect.minY,
                    width: max(usedWidth - start, 1), height: rect.height
                ),
                xRadius: radius, yRadius: radius
            ).fill()
        }
    }

    private static func attributed(
        _ title: String,
        state: LimitState,
        palette: Palette
    ) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: textColor(for: state, palette: palette)]
        )
    }

    /// Цвет цифр. `labelColor` динамический — он разрешается в момент
    /// отрисовки, поэтому подходит и к тёмной, и к светлой строке меню.
    private static func textColor(for state: LimitState, palette: Palette) -> NSColor {
        switch state {
        case .onTrack: .labelColor
        case .overPlan: palette.warning.nsColor
        case .critical, .exhausted: palette.critical.nsColor
        }
    }

    private static func clamp(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }
}
