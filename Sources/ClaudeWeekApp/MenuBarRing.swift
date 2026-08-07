import AppKit
import ClaudeWeekCore

/// Иконка в строке меню: кольцо — пятичасовая сессия, цифра внутри — неделя.
/// Два независимых лимита в одном значке: дуга заполняется по часовой от
/// 12 часов на процент сессии, число в центре говорит про неделю. Цвета у
/// них тоже свои — сессия может гореть красным при спокойной неделе, и
/// наоборот.
enum MenuBarRing {
    /// Диаметр картинки. Чуть больше высоты полосы (16 pt): кольцу нужен
    /// запас под трёхзначный процент, а строка меню (24 pt) его ещё держит.
    static let diameter: CGFloat = 18

    private static let strokeWidth: CGFloat = 1.6
    /// 12 часов — верх круга; в системе координат AppKit это 90°.
    private static let startAngle: CGFloat = 90

    /// `sessionPercent` — процент пятичасового лимита. Его нет (локальная
    /// оценка сессию не считает, окно истекло) — приходит 0, и кольцо стоит
    /// пустым. Недельным процентом дуга не подменяется намеренно: кольцо,
    /// означающее то одно то другое, читать невозможно.
    static func image(
        sessionPercent: Double,
        sessionState: LimitState,
        weekPercent: Double,
        weekState: LimitState,
        palette: Palette = .system
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            drawRing(
                in: rect,
                usedPercent: sessionPercent,
                color: color(for: sessionState, palette: palette),
                palette: palette
            )

            let label = attributed(
                percentText(weekPercent),
                color: color(for: weekState, palette: palette)
            )
            let size = label.size()
            label.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Пустая иконка, пока данных нет.
    static func placeholder(palette: Palette = .system) -> NSImage {
        image(
            sessionPercent: 0, sessionState: .normal,
            weekPercent: 0, weekState: .normal,
            palette: palette
        )
    }

    private static func drawRing(
        in rect: NSRect,
        usedPercent: Double,
        color: NSColor,
        palette: Palette
    ) {
        let bounds = rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = strokeWidth
        palette.track.nsColor.withAlphaComponent(0.65).setStroke()
        track.stroke()

        let fraction = clamp(usedPercent)
        guard fraction > 0 else { return }

        // Полный круг appendArc не рисует (0° и 360° совпадают) — на 100%
        // обходим это на волос меньшим углом, разницы на глаз не видно.
        let sweep = min(360 * fraction, 359.9)
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius,
            startAngle: startAngle, endAngle: startAngle - sweep,
            clockwise: true
        )
        arc.lineWidth = strokeWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private static func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: font(forDigits: text.count), .foregroundColor: color]
        )
    }

    /// Без знака процента и значка оценки — в кольце для них нет места;
    /// то же самое подробно написано в панели.
    private static func percentText(_ usedPercent: Double) -> String {
        Formatting.percent(usedPercent, withSign: false)
    }

    /// Трёхзначный процент (100 и выше) сажаем мельче — иначе цифры вылезают
    /// за кольцо.
    private static func font(forDigits count: Int) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: count >= 3 ? 6.5 : 8, weight: .semibold)
    }

    /// `labelColor` динамический: белый на тёмной строке меню, тёмный на
    /// светлой — «белый круг» из задачи это как раз он на тёмной теме.
    static func color(for state: LimitState, palette: Palette) -> NSColor {
        switch state {
        case .normal: .labelColor
        case .warning: palette.warning.nsColor
        case .critical, .exhausted: palette.critical.nsColor
        }
    }

    private static func clamp(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }
}
