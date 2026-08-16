import AppKit

/// Иконка приложения — то же кольцо, что висит в строке меню, только крупно:
/// шкала недельного лимита, разложенная по порогам. Рисуем кодом, потому что
/// без Xcode собрать ассет-каталог нечем.
///
/// Цвета дуг берутся из родной палитры, тёмной её половины: иконка на плитке
/// Launchpad живёт своей жизнью и на тему системы не смотрит, но роли у цветов
/// те же, что в панели, — и расходиться их оттенки не должны.
enum AppIcon {
    private static let ink = Palette.system

    /// Где зелёное сменяется янтарным и янтарное — красным. Числа не совпадают
    /// с порогами уведомлений (80 и 95 по умолчанию) намеренно: на 16 pt пять
    /// процентов круга вырождаются в одну точку, и красного в знаке попросту
    /// не видно. Тридцать шесть градусов — минимум, который переживает
    /// уменьшение до иконки в Spotlight.
    private static let warningStart: CGFloat = 80
    private static let criticalStart: CGFloat = 90

    /// Плитка. Своих цветов у неё в палитре нет: фон панели рассчитан на текст
    /// поверх материала, а плитке нужен градиент, который читается на любом
    /// рабочем столе. Холодный графит выбран под кольцо — тёплый серый рядом с
    /// зелёным желтит.
    private static let plateTop: UInt32 = 0x2A2E38
    private static let plateBottom: UInt32 = 0x111318

    /// Пары «имя файла в .iconset — сторона в пикселях».
    static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func render(into directory: URL) -> Int32 {
        let iconset = directory.appendingPathComponent("ClaudeWeek.iconset")
        do {
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("не создал \(iconset.path): \(error)\n".utf8))
            return 1
        }

        for variant in variants {
            let image = draw(side: CGFloat(variant.pixels))
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 1 }
            let url = iconset.appendingPathComponent("\(variant.name).png")
            do {
                try png.write(to: url)
            } catch {
                FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                return 1
            }
        }
        print(iconset.path)
        return 0
    }

    private static func draw(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let plate = plateRect(side: side)
            fillPlate(plate)
            drawRing(in: plate)
            return true
        }
    }

    /// Отступ по гайдлайну: плитка не занимает квадрат целиком.
    private static func plateRect(side: CGFloat) -> NSRect {
        let inset = side * 0.055
        return NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    }

    private static func fillPlate(_ rect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        squircle(in: rect).addClip()
        NSGradient(colors: [NSColor(hex: plateTop), NSColor(hex: plateBottom)])?
            .draw(in: rect, angle: -90)
        // Блик по верхней кромке: без него плитка выглядит наклейкой, а не
        // иконкой рядом с системными.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0)])?
            .draw(
                in: NSRect(
                    x: rect.minX, y: rect.maxY - rect.height * 0.4,
                    width: rect.width, height: rect.height * 0.4
                ),
                angle: -90
            )
    }

    /// Форма плитки macOS — суперэллипс, а не прямоугольник со скруглением:
    /// у скруглённого угол ломается там, где дуга встречается с прямой, и
    /// рядом с системными иконками это видно.
    private static func squircle(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let steps = 720
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosT = cos(t), sinT = sin(t)
            let point = NSPoint(
                x: rect.midX + a * copysign(pow(abs(cosT), 2 / exponent), cosT),
                y: rect.midY + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
            )
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }

    private static func drawRing(in plate: NSRect) {
        let center = NSPoint(x: plate.midX, y: plate.midY)
        let radius = plate.width * 0.305
        let width = plate.width * 0.165

        // Соседние дуги перекрываются на полградуса: встык AppKit оставляет
        // волосяную щель, и на мелком размере она читается как грязь.
        let bleed: CGFloat = 0.5
        let warningAngle = warningStart * 3.6
        let criticalAngle = criticalStart * 3.6

        arc(center: center, radius: radius, width: width,
            from: 90, sweep: warningAngle + bleed, color: ink.good.dark)
        arc(center: center, radius: radius, width: width,
            from: 90 - warningAngle, sweep: criticalAngle - warningAngle + bleed,
            color: ink.warning.dark)
        arc(center: center, radius: radius, width: width,
            from: 90 - criticalAngle, sweep: 360 - criticalAngle, color: ink.critical.dark)
    }

    /// 12 часов — верх круга; в системе координат AppKit это 90°, дальше по
    /// часовой стрелке, как заполняется кольцо в строке меню.
    private static func arc(
        center: NSPoint, radius: CGFloat, width: CGFloat,
        from: CGFloat, sweep: CGFloat, color: UInt32
    ) {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center, radius: radius,
            startAngle: from, endAngle: from - min(sweep, 359.9), clockwise: true
        )
        path.lineWidth = width
        path.lineCapStyle = .butt
        NSColor(hex: color).setStroke()
        path.stroke()
    }
}
