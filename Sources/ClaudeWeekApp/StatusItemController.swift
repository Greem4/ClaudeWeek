import AppKit
import SwiftUI
import ClaudeWeekCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let dropdown = DropdownPanel()
    private let model: PanelModel
    private var provider: any UsageProvider

    private var settings: SettingsWindowController?
    private var saveTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var appearanceObserver: NSKeyValueObservation?
    /// Отпечаток файла конфига — по нему замечаем правки без file watcher:
    /// атомарная запись меняет inode, и наблюдатель по дескриптору её теряет.
    private var configStamp: ConfigStamp?

    private let configURL: URL

    init(config: Config = ConfigStore.load(), configURL: URL = ConfigStore.fileURL) {
        self.configURL = configURL
        model = PanelModel(config: config)
        provider = ResolvingProvider(config: config)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configStamp = ConfigStamp.current(url: configURL)
        configureButton()
        configurePanel()
        observeSystemEvents()
        startTimers()
        restoreFromCache()
        render()
        refresh()
    }

    /// Кеш прошлого запуска показываем мгновенно: сетевой ответ придёт через
    /// секунду-другую, и всё это время строка меню иначе висела бы пустой.
    private func restoreFromCache() {
        guard let cache = Store.loadCache(), cache.isFresh(at: Date()) else { return }
        model.apply(cache.snapshot(config: model.config))
        model.status = .stale("данные \(Formatting.age(cache.fetchedAt, now: Date()))")
    }

    // deinit не нужен: контроллер живёт ровно столько же, сколько процесс,
    // а nonisolated deinit всё равно не может трогать таймеры главного актора.

    // MARK: Строка меню

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Цифры нарисованы в картинке, поэтому сами следить за тёмной и
        // светлой строкой меню: на смене оформления перерисовываем.
        appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    private func configurePanel() {
        dropdown.setContent(
            PopoverView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        applyAppearance()
    }

    private func applyAppearance() {
        dropdown.apply(
            appearance: model.config.appearance,
            palette: model.config.appearance.theme.palette
        )
    }

    private func render() {
        guard let button = statusItem.button else { return }

        let title = model.config.menuBarStyle == .compact ? nil : model.menuBarTitle
        let palette = model.config.appearance.theme.palette

        if let snapshot = model.snapshot, let metrics = model.metrics {
            button.image = MenuBarBar.image(
                usedPercent: snapshot.usedPercent,
                planPercent: metrics.planNowPercent,
                state: metrics.state,
                title: title,
                palette: palette
            )
        } else {
            button.image = MenuBarBar.placeholder(title: title, palette: palette)
        }
        // Без текстового заголовка кнопку нечего озвучивать — даём подпись сами.
        button.setAccessibilityLabel("ClaudeWeek — потрачено \(model.menuBarTitle)")
        button.toolTip = tooltip
    }

    private var tooltip: String {
        guard let metrics = model.metrics else { return "ClaudeWeek — данных пока нет" }
        return """
        Потрачено \(Formatting.percent(metrics.usedPercent)) из недельного лимита
        План на сейчас — \(Formatting.percent(metrics.planNowPercent))
        До сброса \(Formatting.duration(metrics.timeLeft))
        """
    }

    // MARK: Действия

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return togglePanel() }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        guard let button = statusItem.button else { return }
        if dropdown.isShown {
            dropdown.close()
        } else {
            model.now = Date()
            dropdown.show(from: button)
            refresh()
        }
    }

    private func showMenu() {
        // Меню встаёт на то же место, что и панель, — сначала убираем её.
        dropdown.close()

        let menu = NSMenu()
        menu.addItem(withTitle: "Обновить", action: #selector(refreshFromMenu), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Настройки…", action: #selector(openConfig), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "О программе", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")
            .target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() { refresh() }

    @objc private func openConfig() { openSettings() }

    /// Окно настроек. Правки применяются сразу и тут же ложатся в файл —
    /// он остаётся источником правды, а окно лишь удобный способ его править.
    private func openSettings() {
        dropdown.close()
        if settings == nil {
            let model = SettingsModel(
                config: model.config,
                apply: { [weak self] config in self?.applyFromSettings(config) },
                check: { config in await Self.check(config: config) }
            )
            settings = SettingsWindowController(model: model)
        }
        settings?.show()
    }

    private func applyFromSettings(_ config: Config) {
        let providerChanged = config.provider != model.config.provider
            || config.authSource != model.config.authSource
            || config.timeZone != model.config.timeZone
            || config.resetWeekday != model.config.resetWeekday
            || config.resetHour != model.config.resetHour
            || config.resetMinute != model.config.resetMinute
            || config.planAnchor != model.config.planAnchor
            || config.weeklyBudget != model.config.weeklyBudget

        model.config = config
        applyAppearance()
        render()

        // Ползунок шлёт по десятку изменений в секунду — на диск ходим
        // с задержкой, применяя к панели каждое сразу.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do {
                try ConfigStore.save(config, to: self.configURL)
                // Свою же запись не перечитываем: отпечаток обновляем сразу,
                // иначе через минуту конфиг применился бы вторым заходом.
                self.configStamp = ConfigStamp.current(url: self.configURL)
            } catch {
                Log.warn("не сохранил настройки: \(error)")
            }
        }

        guard providerChanged else { return }
        provider = ResolvingProvider(config: config)
        startTimers()
        refresh()
    }

    /// Одна честная попытка сходить в официальный источник — чтобы кнопка
    /// «Проверить» в настройках отвечала не «сохранено», а «работает».
    private static func check(config: Config) async -> (String, Bool) {
        var config = config
        config.provider = .official
        do {
            let snapshot = try await ResolvingProvider(config: config).fetch()
            return ("получилось: \(Formatting.percent(snapshot.usedPercent)) недельного лимита", true)
        } catch {
            let text = (error as? UsageError)?.errorDescription ?? error.localizedDescription
            return (text, false)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "ClaudeWeek \(ClaudeWeek.version)"
        alert.informativeText = """
        Недельный лимит Claude Code одним взглядом.
        Конфигурация: \(configURL.path)
        """
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Жизненный цикл

    private func startTimers() {
        refreshTimer?.invalidate()
        let interval = max(model.config.refreshInterval, Config.minimumRefreshInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Разрешаем системе сдвигать срабатывание — это экономит пробуждения
        // процессора и никак не вредит: данные обновляются раз в минуты.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        guard clockTimer == nil else { return }
        let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clock.tolerance = 10
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock
    }

    /// Раз в минуту: двигаем «до сброса» и проверяем, не правил ли кто конфиг.
    private func tick() {
        model.now = Date()
        reloadConfigIfChanged()
        render()
    }

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(timeZoneChanged),
            name: .NSSystemTimeZoneDidChange, object: nil
        )
    }

    /// Пока Mac спит, тикать некуда: гасим таймер, чтобы не копить
    /// просроченные срабатывания и не будить сеть сразу пачкой.
    @objc private func willSleep() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func didWake() {
        startTimers()
        tick()
        refresh()
    }

    /// Окно недели считается в локальной таймзоне, поэтому её смена меняет
    /// и границы суток — пересчитываем целиком.
    @objc private func timeZoneChanged() {
        Log.info("сменилась системная таймзона, пересчитываю окно")
        tick()
        refresh()
    }

    private func reloadConfigIfChanged() {
        let stamp = ConfigStamp.current(url: configURL)
        guard stamp != configStamp else { return }
        configStamp = stamp

        let config = ConfigStore.load(from: configURL)
        guard config != model.config else { return }
        Log.info("конфиг изменился, применяю")
        model.config = config
        applyAppearance()
        provider = ResolvingProvider(config: config)
        startTimers()
        refresh()
    }

    // MARK: Обновление

    func refresh() {
        guard !model.isRefreshing else { return }
        model.isRefreshing = true
        let provider = provider

        Task { [weak self] in
            do {
                let snapshot = try await provider.fetch()
                self?.model.apply(snapshot)
            } catch {
                Log.warn("не смог обновить данные: \(error)")
                self?.model.apply(error: error)
            }
            self?.model.isRefreshing = false
            self?.render()
        }
    }
}
