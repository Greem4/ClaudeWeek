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
            session: SessionUsage(usedPercent: 41, resetsAt: now.addingTimeInterval(84 * 60)),
            byModel: demoModels()
        )
    }

    /// Разбивка макета: Opus дороже всех при вчетверо меньшем числе токенов —
    /// ровно то расхождение, ради которого окно и открывают.
    private static func demoModels() -> [ModelUsage] {
        let rows: [(String, Double, TokenCounts, Int)] = [
            (ModelFamily.opus, 7.5,
             TokenCounts(input: 1_240_000, output: 186_000, cacheWrite: 3_400_000, cacheRead: 41_800_000), 342),
            (ModelFamily.sonnet, 2.2,
             TokenCounts(input: 860_000, output: 124_000, cacheWrite: 2_100_000, cacheRead: 28_400_000), 268),
            (ModelFamily.haiku, 0.7,
             TokenCounts(input: 410_000, output: 52_000, cacheWrite: 640_000, cacheRead: 9_300_000), 96),
        ]
        let total = rows.reduce(0) { $0 + $1.1 }
        return rows.map { family, cost, tokens, messages in
            ModelUsage(
                family: family,
                cost: cost,
                tokens: tokens,
                messages: messages,
                sharePercent: cost / total * 100
            )
        }
    }

    static func render(into directory: URL, config: Config) -> Int32 {
        // Момент внутри пятой строки окна — как на макете, где следующие
        // сутки ещё пусты.
        let now = WeekWindow(containing: Date(), config: config)
            .dayStart(4)
            .addingTimeInterval(6 * 3600)

        var config = config
        // Картинки идут в README, и выглядеть они должны одинаково, чей бы
        // конфиг ни лежал рядом: у автора может стоять компактная панель,
        // своя палитра и свои пороги — в документации это читалось бы как
        // поведение программы. Вид и пороги берём заводские, окно недели и
        // рабочий день оставляем из конфига: от них зависят подписи строк.
        config.appearance = AppearanceConfig()
        config.thresholds = Thresholds()
        // Порядок строк — тоже вид, а не окно: картинки должны показывать
        // заводскую неделю от понедельника, чей бы конфиг ни лежал рядом.
        config.weekStart = Config.default.weekStart
        // Два отступления от заводского вида, оба ради одной и той же
        // картинки: панель из коробки короче — без дневного плана и с
        // компактным рядом, — а в README нужно показать то, ради чего
        // программа написана, — все семь суток разом с плановой зоной. Как
        // свернуть их обратно, сказано в руководстве.
        config.appearance.showsPlan = true
        config.appearance.panelLayout = .week
        // Материал строки меню в оффскрин-рендер не попадает — фон рисуем
        // сплошным цветом палитры.
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

        // Та же панель в разбивке по моделям: строки дней сменились строками
        // моделей. Снимок нужен ровно затем же, зачем остальные, — проверить
        // вёрстку глазами, не открывая панель руками.
        model.showsModels = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let image = image(model: model, appearance: appearance),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("не отрисовал разбивку \(name)\n".utf8))
                return 1
            }
            let url = directory.appendingPathComponent("panel-models-\(name).png")
            do {
                try png.write(to: url)
                print(url.path)
            } catch {
                FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                return 1
            }
        }
        model.showsModels = false

        // Вкладка уведомлений: единственная настройка, которую по панели не
        // видно — баннер приходит мимо неё, — и объяснить её в документации
        // без картинки нечем.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let image = notificationsTab(config: config, appearance: appearance),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("не отрисовал уведомления \(name)\n".utf8))
                return 1
            }
            let url = directory.appendingPathComponent("settings-notifications-\(name).png")
            do {
                try png.write(to: url)
                print(url.path)
            } catch {
                FileHandle.standardError.write(Data("не сохранил \(url.path): \(error)\n".utf8))
                return 1
            }
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let strip = menuBarPNG(model: model, appearance: appearance, ring: false) else {
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
            guard let ringStrip = menuBarPNG(model: model, appearance: appearance, ring: true) else { return 1 }
            let ringURL = directory.appendingPathComponent("menubar-ring-\(name).png")
            try? ringStrip.write(to: ringURL)
            print(ringURL.path)
        }
        return 0
    }

    /// Иконка строки меню на кусочке фона, увеличенная вчетверо: в реальном
    /// масштабе 28×16 pt глазами не проверишь.
    private static func menuBarPNG(model: PanelModel, appearance name: NSAppearance.Name, ring: Bool) -> Data? {
        guard let appearance = NSAppearance(named: name),
              let snapshot = model.snapshot,
              let metrics = model.metrics
        else { return nil }

        let scale: CGFloat = 4
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let arc = model.config.ringArc
            let onArc = model.ringLimit(arc)
            let inside = model.ringLimit(arc.label)
            let icon = ring
                ? MenuBarRing.image(
                    arcPercent: onArc.percent, arcState: onArc.state,
                    labelPercent: inside.percent, labelState: inside.state,
                    colorize: model.colorizesMenuBar
                )
                : MenuBarBar.image(
                    usedPercent: snapshot.usedPercent,
                    planPercent: metrics.planNowPercent,
                    state: model.state,
                    title: model.menuBarTitle,
                    colorize: model.colorizesMenuBar
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

    /// Вкладка «Уведомления» с заводскими порогами. Модель настроек здесь
    /// холостая: правки уходят в никуда, проверка токена не зовётся, а
    /// контроллер уведомлений собран как у настоящего приложения — иначе
    /// снимок объяснял бы, что у отладочного бинаря баннеров не бывает.
    private static func notificationsTab(config: Config, appearance name: NSAppearance.Name) -> NSImage? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var config = config
        config.notifications = NotificationsConfig()

        let model = SettingsModel(
            config: config,
            update: UpdateController(bundle: nil),
            notifications: NotificationController(bundled: true),
            apply: { _ in },
            check: { _ in ("", true) },
            reset: {}
        )

        // Высота больше оконной: в живом окне вкладка прокручивается, а на
        // картинке нужны все секции разом — иначе нижнюю половину настроек
        // пришлось бы пересказывать словами. Пороги — с ходу раскрытыми:
        // свёрнутая по умолчанию секция на этом снимке прятала бы то, ради
        // чего он вообще существует.
        return hosted(
            NotificationSettings(model: model, showsAdvanced: true)
                .environment(\.colorScheme, name == .darkAqua ? .dark : .light),
            size: NSSize(width: SettingsView.width, height: 780),
            appearance: appearance
        )
    }

    /// Снимок вида через настоящее окно, а не `ImageRenderer`. Форма со
    /// стилем `.grouped` — это AppKit-таблица под тонким слоем SwiftUI, и
    /// рендерер, не знающий про окно, отдаёт вместо неё пустой прямоугольник.
    ///
    /// Окно приходится сделать ключевым и на мгновение показать: в неактивном
    /// окне macOS красит переключатели серым, и включённые настройки на
    /// картинке читались бы как выключенные. Убираем его сразу после снимка.
    private static func hosted(
        _ view: some View, size: NSSize, appearance: NSAppearance
    ) -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        window.layoutIfNeeded()
        // Ключевое окно тут не украшательство: в неактивном macOS красит
        // переключатели серым, и включённые настройки на картинке читались бы
        // как выключенные. Приложение при этом ещё не запущено (`--screenshot`
        // отрабатывает до `NSApp.run()`), поэтому запускаем его вручную и сами
        // прокачиваем очередь событий — без неё активация не доходит.
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pumpEvents(for: 0.6)
        hosting.displayIfNeeded()

        // Вдвое крупнее, как и остальные картинки документации: на Retina
        // однократный снимок выглядит мылом.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        context.cgContext.scaleBy(x: scale, y: scale)
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        window.orderOut(nil)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Разбирает очередь событий заданное время: `RunLoop.run(until:)` тут не
    /// годится — активацией окна и разметкой SwiftUI занимается сам
    /// `NSApplication`, и события должны пройти через него.
    private static func pumpEvents(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(
                matching: .any, until: deadline, inMode: .default, dequeue: true
            ) else { break }
            NSApp.sendEvent(event)
        }
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
            // Контроллер обновления — пустой и без бандла: картинкам в
            // документации незачем показывать новость, которая была свежей
            // в день съёмки.
            let renderer = ImageRenderer(
                content: PopoverView(model: model, update: UpdateController(bundle: nil))
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
