import AppKit
import SwiftUI
import ClaudeWeekCore

/// `--screenshot <каталог>` рисует панель в обеих темах без запуска UI.
/// Нужен, чтобы проверять вёрстку глазами и прикладывать картинки к PR.
@MainActor
enum Screenshot {
    /// Числа из макета плана (§1): факт 7/15/28/58 против плана 7/21/36/50.
    static func demoSnapshot(config: Config, now: Date) -> UsageSnapshot {
        let window = WeekWindow(containing: now, config: config)
        return UsageSnapshot.make(
            usedPercent: 58,
            cumulativeByDay: [7, 15, 28, 58, nil, nil, nil],
            window: window,
            source: .official,
            fetchedAt: now,
            isEstimate: false
        )
    }

    static func render(into directory: URL, config: Config) -> Int32 {
        // Момент внутри четвёртых суток окна — как на макете, где ВТ ещё пуст.
        let now = WeekWindow(containing: Date(), config: config)
            .dayStart(3)
            .addingTimeInterval(6 * 3600)

        let model = PanelModel(config: config)
        model.apply(demoSnapshot(config: config, now: now))
        model.now = now

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("не создал каталог: \(error)\n".utf8))
            return 1
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let image = image(model: model, appearance: appearance) else {
                FileHandle.standardError.write(Data("не отрисовал \(name)\n".utf8))
                return 1
            }
            let url = directory.appendingPathComponent("panel-\(name).png")
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 1 }
            do {
                try png.write(to: url)
                print(url.path)
            } catch {
                FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                return 1
            }
        }
        return 0
    }

    private static func image(model: PanelModel, appearance name: NSAppearance.Name) -> NSImage? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var result: NSImage?
        // Оффскрин-рендеру мало установить NSAppearance: динамические цвета
        // SwiftUI разрешает по colorScheme из окружения, поэтому задаём оба.
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(
                content: PopoverView(model: model)
                    .environment(\.colorScheme, name == .darkAqua ? .dark : .light)
            )
            renderer.scale = 2
            result = renderer.nsImage
        }
        return result
    }
}
