import AppKit
import ClaudeWeekCore

/// Картинка к уведомлению — сводка по тому лимиту, о котором речь: с какого
/// момента идёт его окно, сколько израсходовано и на какую модель ушло больше
/// всего.
///
/// Раньше здесь были дуга у сессии и число у недели — одна крупная форма на
/// всю плашку. От неё отказались: развёрнутый баннер показывает вложение
/// большим, и место, где помещается статистика окна, занимала цифра, уже
/// написанная в первой строке текста. Какой это лимит, теперь говорит подпись
/// сверху («Неделя с СБ», «Сессия с 17:30»), а цвет полосы остался прежним
/// языком тревоги.
///
/// Цвет берётся по порогам самого уведомления, а не по цветовым со вкладки
/// «Строка меню»: те стоят на своих отметках, и баннер о пробитом пороге
/// приходил бы со спокойным зелёным числом просто потому, что до окраски
/// значка не хватило процента.
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
        percent: Double,
        state: LimitState,
        window: String?,
        model: String?,
        palette: Palette,
        appearance: NSAppearance? = nil
    ) -> URL? {
        guard let data = render(
            percent: percent, state: state, window: window, model: model,
            palette: palette, appearance: appearance
        ) else { return nil }
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
        percent: Double,
        state: LimitState,
        window: String?,
        model: String?,
        palette: Palette,
        appearance: NSAppearance? = nil
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
        //
        // Явное оформление просит только генератор картинок для документации:
        // ему нужны обе темы разом, а не та, в которой запущен процесс. Там же
        // `NSApp` может не оказаться вовсе — под `--screenshot` картинки
        // рисуются до того, как поднят UI, и запасное оформление здесь честнее
        // падения на неявной распаковке.
        let drawing = appearance ?? NSApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua) ?? NSAppearance()
        drawing.performAsCurrentDrawingAppearance {
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Цвет берётся по порогам уведомлений: первый порог — жёлтый,
            // второй и исчерпанный лимит — красный. Чем выше расход, тем
            // тревожнее полоса, и оба баннера говорят это одним языком.
            let ink = color(for: state, palette: palette)
            drawCard(percent: percent, window: window, model: model, ink: ink, palette: palette)
            NSGraphicsContext.restoreGraphicsState()
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    /// Сводка окна: подпись сверху, крупный процент с полосой под ним и
    /// строка о главной модели внизу.
    ///
    /// Процент оставлен крупным намеренно. В свёрнутом баннере вложение —
    /// квадратик в палец шириной, и подписи в нём не читаются вовсе; читается
    /// только число и цвет. Статистика вокруг него написана для развёрнутого
    /// вида, где места втрое больше.
    private static func drawCard(
        percent: Double, window: String?, model: String?, ink: NSColor, palette: Palette
    ) {
        let box = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        let margin = box.width * 0.08

        // Сверху вниз: подпись окна, число, полоса, модель. Координаты AppKit
        // растут вверх, поэтому кладём с нижнего края.
        if let window {
            draw(window, size: box.width * 0.085, weight: .semibold,
                 color: .secondaryLabelColor, centeredIn: box,
                 y: box.height - margin - box.width * 0.1)
        }
        if let model {
            draw(model, size: box.width * 0.075, weight: .regular,
                 color: .secondaryLabelColor, centeredIn: box, y: margin)
        }

        let number = Formatting.percent(percent, withSign: false)
        let font = fitted(number, toWidth: box.width * 0.52, maxSize: box.height * 0.42)
        let label = NSAttributedString(
            string: number, attributes: [.font: font, .foregroundColor: ink]
        )
        let size = label.size()
        label.draw(at: NSPoint(x: (box.width - size.width) / 2, y: box.midY - size.height * 0.22))

        drawBar(
            percent: percent,
            in: NSRect(x: margin, y: box.height * 0.30,
                       width: box.width - margin * 2, height: box.width * 0.075),
            ink: ink,
            palette: palette
        )
    }

    /// Полоса расхода: дорожка во всю ширину и залитая часть по проценту.
    /// Перебор за 100 % не рисуем — полоса и так упёрлась в край, а вылезший
    /// прямоугольник читался бы как ошибка отрисовки.
    private static func drawBar(percent: Double, in rect: NSRect, ink: NSColor, palette: Palette) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        palette.track.nsColor.withAlphaComponent(0.65).setFill()
        track.fill()

        let fraction = min(max(percent, 0), 100) / 100
        guard fraction > 0 else { return }
        // Совсем узкая заливка выглядит обрубком: держим её не уже высоты,
        // чтобы скругление осталось скруглением.
        let width = max(rect.width * fraction, rect.height)
        let filled = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let path = NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius)
        ink.setFill()
        path.fill()
    }

    /// Кегль, при котором строка укладывается в отведённую ширину: «7», «82» и
    /// «100» — строки разной длины, и с постоянным кеглем короткая терялась бы,
    /// а длинная не влезала.
    private static func fitted(_ text: String, toWidth width: CGFloat, maxSize: CGFloat) -> NSFont {
        let probe: CGFloat = 100
        let probeWidth = (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: probe, weight: .bold)]).width
        return NSFont.systemFont(ofSize: min(probe * width / max(probeWidth, 1), maxSize), weight: .bold)
    }

    /// Строка по центру плашки. Длинную ужимаем по ширине, а не переносим:
    /// перенос в картинке размером с ноготь превращается в кашу.
    private static func draw(
        _ text: String, size: CGFloat, weight: NSFont.Weight,
        color: NSColor, centeredIn box: NSRect, y: CGFloat
    ) {
        let available = box.width * 0.92
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        var width = (text as NSString).size(withAttributes: [.font: font]).width
        if width > available {
            font = NSFont.systemFont(ofSize: size * available / width, weight: weight)
            width = (text as NSString).size(withAttributes: [.font: font]).width
        }
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            .draw(at: NSPoint(x: (box.width - width) / 2, y: y))
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
