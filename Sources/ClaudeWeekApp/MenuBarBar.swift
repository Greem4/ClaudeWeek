import AppKit
import ClaudeWeekCore

/// Мини-полоска слева от процента в строке меню: те же три цвета, что и в
/// панели, только в 24×3 pt.
enum MenuBarBar {
    static let size = NSSize(width: 24, height: 3)

    static func image(usedPercent: Double, planPercent: Double, state: LimitState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = rect.height / 2

            NSColor(hex: 0x8A8A85).withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

            let planWidth = rect.width * clamp(planPercent)
            NSColor(hex: 0x6DA7EC).withAlphaComponent(0.65).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: planWidth, height: rect.height),
                xRadius: radius, yRadius: radius
            ).fill()

            let usedWidth = rect.width * clamp(usedPercent)
            let insidePlan = min(usedWidth, planWidth)
            NSColor(hex: 0x0CA30C).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: insidePlan, height: rect.height),
                xRadius: radius, yRadius: radius
            ).fill()

            if usedWidth > planWidth {
                // Тот же двухпиксельный зазор, что и в панели.
                let start = planWidth + 2
                let width = max(usedWidth - start, 1)
                NSColor(hex: state == .exhausted ? 0xD03B3B : 0xFAB219).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: start, y: 0, width: width, height: rect.height),
                    xRadius: radius, yRadius: radius
                ).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Пустая полоска, пока данных нет.
    static func placeholder() -> NSImage {
        image(usedPercent: 0, planPercent: 0, state: .onTrack)
    }

    private static func clamp(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }
}
