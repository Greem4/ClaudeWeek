import AppKit
import ClaudeWeekCore

/// Картинка к уведомлению. Нужна не для красоты: по ней видно, о каком из двух
/// лимитов речь, ещё до того, как прочитан текст, — поэтому лимиты нарисованы
/// по-разному.
///
/// Пятичасовая сессия приходит **дугой**, недельный лимит — **числом**. Это тот
/// же язык, каким говорит значок в строке меню: там дуга по умолчанию отдана
/// сессии, а цифра в центре — неделе. Один взгляд на баннер — и понятно,
/// кончается пятичасовое окно или неделя, а текст только уточняет, сколько
/// именно.
///
/// Цвет берётся по тем же порогам, что красят значок, а не по порогу
/// уведомления: человек привык, что жёлтое кольцо у часов означает одно и то
/// же, и баннер, спорящий с ним цветом, читался бы как второй, другой лимит.
///
/// Живёт на главном акторе: оформление, в котором разрешаются цвета палитры,
/// спрашивается у самого приложения.
@MainActor
enum AlertArtwork {
    /// Сторона картинки в пикселях. Баннер показывает вложение маленьким
    /// квадратом, но в Центре уведомлений и на Retina оно разворачивается
    /// крупнее — рисуем с запасом, места это стоит килобайты.
    private static let side = 256

    /// PNG во временном файле. `UNNotificationAttachment` забирает файл себе,
    /// поэтому имя каждый раз новое: отданный однажды файл к следующему
    /// баннеру уже не принадлежит нам.
    ///
    /// Не вышло — nil, и уведомление уйдёт без картинки: текст в нём главное,
    /// и терять весь баннер из-за неудавшейся отрисовки незачем.
    static func png(
        percent: Double, state: LimitState, kind: AlertKind, palette: Palette
    ) -> URL? {
        guard let data = render(percent: percent, state: state, kind: kind, palette: palette)
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeweek-alert-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.warn("не сохранил картинку уведомления: \(error)")
            return nil
        }
    }

    private static func render(
        percent: Double, state: LimitState, kind: AlertKind, palette: Palette
    ) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)

        var data: Data?
        // Цвета палитры динамические — их разрешает текущее оформление. У
        // оффскрин-рендера его нет, поэтому берём то, в котором живёт само
        // приложение: баннер ляжет на фон той же системной темы.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Цвет один на обе формы и берётся по порогам уведомлений: первый
            // порог — жёлтый, второй и исчерпанный лимит — красный. Так дуга и
            // число говорят одно и то же одним языком, а разные красные в паре
            // баннеров не читаются как два разных смысла.
            let ink = color(for: state, palette: palette)
            switch kind {
            case .session: drawArc(percent: percent, color: ink, palette: palette)
            case .week: drawNumber(percent: percent, color: ink)
            }
            NSGraphicsContext.restoreGraphicsState()
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    /// Пятичасовая сессия: кольцо, заполненное израсходованным. Числа внутри
    /// нет — его говорит первая строка баннера, а пустая середина как раз и
    /// отличает сессию от недели с одного взгляда.
    private static func drawArc(percent: Double, color: NSColor, palette: Palette) {
        let box = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        let stroke = box.width * 0.14
        let bounds = box.insetBy(dx: stroke / 2 + box.width * 0.04, dy: stroke / 2 + box.width * 0.04)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = stroke
        palette.track.nsColor.withAlphaComponent(0.65).setStroke()
        track.stroke()

        let fraction = min(max(percent, 0), 100) / 100
        guard fraction > 0 else { return }
        // Тот же приём, что в значке: полный круг `appendArc` не рисует,
        // и на 100 % дуга не замыкается на волос.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius,
            startAngle: 90, endAngle: 90 - min(360 * fraction, 359.9),
            clockwise: true
        )
        arc.lineWidth = stroke
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    /// Недельный лимит: одно число во всю плашку — без знака процента. Знак в
    /// миниатюре съедает половину места и ничего не добавляет: в первой строке
    /// баннера уже написано «Израсходовано 82 %», а картинка должна читаться
    /// на бегу, одним крупным числом.
    ///
    /// Кегль не задан числом, а подобран под ширину: «7», «82» и «100» —
    /// строки разной длины, и с постоянным кеглем короткая терялась бы в углу,
    /// а длинная не влезала.
    private static func drawNumber(percent: Double, color: NSColor) {
        let box = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        let text = Formatting.percent(percent, withSign: false)

        // Меряем пробной строкой и масштабируем: так строка занимает по ширине
        // ровно то, что ей отведено, какой бы длины ни оказалась.
        let probe: CGFloat = 100
        let probeWidth = (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: probe, weight: .bold)]).width
        let byWidth = probe * (box.width * 0.86) / max(probeWidth, 1)
        let font = NSFont.systemFont(ofSize: min(byWidth, box.height * 0.78), weight: .bold)

        let label = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]
        )
        let size = label.size()
        label.draw(at: NSPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2))
    }

    /// Спокойное состояние здесь зелёное, а не нейтральное, как в строке меню:
    /// нейтральный цвет там берётся у текста строки, а на прозрачном фоне
    /// баннера такого цвета нет — картинка вышла бы то белой, то чёрной.
    private static func color(for state: LimitState, palette: Palette) -> NSColor {
        switch state {
        case .normal: palette.good.nsColor
        case .warning: palette.warning.nsColor
        case .critical, .exhausted: palette.critical.nsColor
        }
    }
}
