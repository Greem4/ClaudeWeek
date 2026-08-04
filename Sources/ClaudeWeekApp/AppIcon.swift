import AppKit

/// Иконка приложения — та же метафора, что и в панели: три полосы недели,
/// где зелёная упирается в янтарную. Рисуем кодом, потому что без Xcode
/// собрать ассет-каталог нечем.
enum AppIcon {
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
            // macOS сама не скругляет иконку — рисуем «сквиркл» вручную,
            // с отступом по гайдлайну (примерно десятая часть стороны).
            let inset = side * 0.08
            let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            let corner = plate.width * 0.22

            NSColor(hex: 0x1A1A19).setFill()
            NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner).fill()

            let barHeight = plate.height * 0.11
            let spacing = plate.height * 0.10
            let left = plate.minX + plate.width * 0.14
            let usable = plate.width * 0.72
            let radius = barHeight / 2
            let totalHeight = barHeight * 3 + spacing * 2
            var y = plate.midY + totalHeight / 2 - barHeight

            // Сверху вниз: недобор, ровно по плану, перерасход.
            let rows: [(fill: Double, plan: Double)] = [
                (0.45, 0.70),
                (0.70, 0.70),
                (0.95, 0.70),
            ]

            for row in rows {
                NSColor(hex: 0x2C2C2A).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: left, y: y, width: usable, height: barHeight),
                    xRadius: radius, yRadius: radius
                ).fill()

                NSColor(hex: 0x3987E5).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: left, y: y, width: usable * row.plan, height: barHeight),
                    xRadius: radius, yRadius: radius
                ).fill()

                NSColor(hex: 0x0CA30C).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: left, y: y,
                        width: usable * min(row.fill, row.plan), height: barHeight
                    ),
                    xRadius: radius, yRadius: radius
                ).fill()

                if row.fill > row.plan {
                    let gap = max(side * 0.012, 1)
                    let start = left + usable * row.plan + gap
                    NSColor(hex: 0xFAB219).setFill()
                    NSBezierPath(
                        roundedRect: NSRect(
                            x: start, y: y,
                            width: max(left + usable * row.fill - start, 1), height: barHeight
                        ),
                        xRadius: radius, yRadius: radius
                    ).fill()
                }

                y -= barHeight + spacing
            }
            return true
        }
    }
}
