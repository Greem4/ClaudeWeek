import AppKit
import SwiftUI
import ClaudeWeekCore

/// `--screenshot <каталог>` рисует панель и иконку строки меню в обеих темах
/// без запуска UI. Нужен, чтобы проверять вёрстку глазами и прикладывать
/// картинки к PR.
@MainActor
enum Screenshot {
    /// Числа макета плана (§1), разложенные по календарным строкам: неделя
    /// начинается вечером пятницы, поэтому первая строка короткая и почти
    /// пустая, а основной расход приходится на полные сутки.
    static func demoSnapshot(config: Config, now: Date) -> UsageSnapshot {
        let window = WeekWindow(containing: now, config: config)
        let shape: [Double?] = [2, 7, 15, 28, 58, nil, nil, nil]
        return UsageSnapshot.make(
            usedPercent: 58,
            cumulativeByDay: Array(shape.prefix(window.slotCount)),
            window: window,
            source: .official,
            fetchedAt: now,
            isEstimate: false,
            session: SessionUsage(usedPercent: 41, resetsAt: now.addingTimeInterval(84 * 60))
        )
    }

    static func render(into directory: URL, config: Config) -> Int32 {
        // Момент внутри пятой строки окна — как на макете, где следующие
        // сутки ещё пусты.
        let now = WeekWindow(containing: Date(), config: config)
            .dayStart(4)
            .addingTimeInterval(6 * 3600)

        var config = config
        config.appearance.transparentPanel = false
        let model = PanelModel(config: config)
        model.apply(demoSnapshot(config: config, now: now), at: now)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("не создал каталог: \(error)\n".utf8))
            return 1
        }

        // Каждая тема в обеих системных оформлениях: галерея в README должна
        // показывать, что палитра выбирается, а не подбирается пересборкой.
        for theme in ThemeKind.allCases {
            model.config.appearance.theme = theme
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let image = image(model: model, appearance: appearance),
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(Data("не отрисовал \(theme.rawValue) \(name)\n".utf8))
                    return 1
                }

                // Родная палитра лежит и под коротким именем: на неё ссылаются
                // README и прежние ссылки в задачах.
                var files = ["panel-\(theme.rawValue)-\(name).png"]
                if theme == .system { files.append("panel-\(name).png") }

                for file in files {
                    let url = directory.appendingPathComponent(file)
                    do {
                        try png.write(to: url)
                        print(url.path)
                    } catch {
                        FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                        return 1
                    }
                }
            }
        }

        model.config.appearance.theme = config.appearance.theme
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let strip = menuBarPNG(model: model, appearance: appearance) else {
                FileHandle.standardError.write(Data("не отрисовал иконку \(name)\n".utf8))
                return 1
            }
            let url = directory.appendingPathComponent("menubar-\(name).png")
            do {
                try strip.write(to: url)
                print(url.path)
            } catch {
                FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                return 1
            }
        }
        return 0
    }

    /// Иконка строки меню на кусочке фона, увеличенная вчетверо: в реальном
    /// масштабе 28×16 pt глазами не проверишь.
    private static func menuBarPNG(model: PanelModel, appearance name: NSAppearance.Name) -> Data? {
        guard let appearance = NSAppearance(named: name),
              let snapshot = model.snapshot,
              let metrics = model.metrics
        else { return nil }

        let scale: CGFloat = 4
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let icon = MenuBarBar.image(
                usedPercent: snapshot.usedPercent,
                planPercent: metrics.planNowPercent,
                state: metrics.state,
                title: model.menuBarTitle
            )
            // Высота полосы меню macOS — 24 pt, поля по 6 pt как у соседей.
            let size = NSSize(width: icon.size.width + 12, height: 24)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = size

            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(hex: name == .darkAqua ? 0x2A2A28 : 0xF0EFEA).setFill()
            NSRect(origin: .zero, size: size).fill()
            icon.draw(at: NSPoint(x: 6, y: (size.height - icon.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    private static func image(model: PanelModel, appearance name: NSAppearance.Name) -> NSImage? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var result: NSImage?
        // Оффскрин-рендеру мало установить NSAppearance: динамические цвета
        // SwiftUI разрешает по colorScheme из окружения, поэтому задаём оба.
        appearance.performAsCurrentDrawingAppearance {
            // Живьём панель лежит на материале строки меню, размыть который
            // оффскрин нельзя, поэтому модели на время рендера выключаем
            // прозрачность — фон рисуется сплошным цветом палитры. Форму
            // сохраняем: те же скруглённые углы и тень, что видит человек.
            let radius = model.config.appearance.cornerRadius
            let renderer = ImageRenderer(
                content: PopoverView(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                    .padding(16)
                    .environment(\.colorScheme, name == .darkAqua ? .dark : .light)
            )
            renderer.scale = 2
            result = renderer.nsImage
        }
        return result
    }
}
