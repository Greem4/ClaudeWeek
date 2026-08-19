import AppKit
import SwiftUI
import ClaudeWeekCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let dropdown = DropdownPanel()
    private let model: PanelModel

    /// Строки меню и подсказок. Берутся из той же модели, что и панель, —
    /// у AppKit-частей нет окружения SwiftUI, но конфиг у них общий.
    private var s: L10n { model.strings }
    private var provider: any UsageProvider
    private let update = UpdateController()
    private let notifications = NotificationController()

    private var settings: SettingsWindowController?
    private var saveTask: Task<Void, Never>?
    /// Конфиг, ждущий записи из-под дебаунса. Держим отдельно от захвата в
    /// замыкании `saveTask`: без него правку, попавшую в эту задержку,
    /// нечем было бы дописать синхронно на `applicationWillTerminate` —
    /// `Task.sleep` до выхода просто не успевает.
    private var pendingConfigWrite: Config?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    /// Будильник на момент сброса недели. Плановый опрос идёт раз в несколько
    /// минут, и без него панель показывала бы исчерпанный лимит ещё весь этот
    /// круг после обнуления.
    private var resetTimer: Timer?
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
        update.strings = config.strings
        update.start()
        // Разрешение на баннеры спрашиваем сразу, а не в момент первого
        // порога: системный диалог, выскочивший посреди работы через три дня
        // после установки, читается как выходка, а на первом запуске он
        // ожидаем. Выключенные уведомления не спрашивают ничего.
        notifications.apply(config.notifications)
        // Разбивку за пятичасовое окно считает провайдер: берём текущий, а не
        // запомненный, — при смене источника в настройках он пересоздаётся.
        update.onFound = { [weak self] release in
            guard let self else { return }
            notifications.announceUpdate(release, config: model.config)
        }
        notifications.models = { [weak self] from, to in
            // Разбивку умеет считать только `ResolvingProvider` — он и стоит
            // здесь всегда. Каст на случай подмены дублёром: баннер тогда
            // придёт без строки о модели, а не упадёт.
            guard let provider = self?.provider as? ResolvingProvider else { return [] }
            return await provider.models(from: from, to: to)
        }
        restoreFromCache()
        render()
        refresh()
    }

    /// Кеш прошлого запуска показываем мгновенно: сетевой ответ придёт через
    /// секунду-другую, и всё это время строка меню иначе висела бы пустой.
    /// Возраст подписывает сама модель — правило свежести одно на всех.
    private func restoreFromCache() {
        guard let cache = Store.loadCache(), cache.isFresh(at: Date()) else { return }
        let snapshot = cache.snapshot(config: model.config)
        model.apply(snapshot)
        // Кеш — такой же повод сказать про лимит, как свежий ответ: машину
        // перезагрузили посреди недели, и до первого ответа сервера человек
        // иначе не узнал бы, что расход уже за порогом. Повториться это не
        // даст лог сказанного.
        notifications.consider(snapshot, config: model.config)
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
                update: update,
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

        button.image = menuBarImage(palette: model.config.appearance.theme.palette)
        // Без текстового заголовка кнопку нечего озвучивать — даём подпись сами.
        button.setAccessibilityLabel(s.pick("ClaudeWeek — потрачено \(model.menuBarTitle)",
                                            "ClaudeWeek — \(model.menuBarTitle) spent"))
        button.toolTip = tooltip
    }

    /// Картинка кнопки: три стиля на выбор в настройках — полоса с числом,
    /// одна полоса или кольцо с числом внутри.
    private func menuBarImage(palette: Palette) -> NSImage {
        guard let snapshot = model.snapshot, let metrics = model.metrics else {
            switch model.config.menuBarStyle {
            case .percent: return MenuBarBar.placeholder(title: model.menuBarTitle, palette: palette)
            case .compact: return MenuBarBar.placeholder(title: nil, palette: palette)
            case .ring: return MenuBarRing.placeholder(palette: palette)
            }
        }
        switch model.config.menuBarStyle {
        case .percent:
            return MenuBarBar.image(
                usedPercent: snapshot.usedPercent, planPercent: metrics.planNowPercent,
                state: model.state, title: model.menuBarTitle,
                colorize: model.colorizesMenuBar, palette: palette
            )
        case .compact:
            return MenuBarBar.image(
                usedPercent: snapshot.usedPercent, planPercent: metrics.planNowPercent,
                state: model.state, title: nil,
                colorize: model.colorizesMenuBar, palette: palette
            )
        case .ring:
            // Какой лимит заполняет дугу, а какой стоит цифрой — дело
            // настройки; сюда они приходят уже разложенными по местам.
            let arc = model.config.ringArc
            let onArc = model.ringLimit(arc)
            let inside = model.ringLimit(arc.label)
            return MenuBarRing.image(
                arcPercent: onArc.percent, arcState: onArc.state,
                labelPercent: inside.percent, labelState: inside.state,
                colorize: model.colorizesMenuBar,
                palette: palette
            )
        }
    }

    /// Кольцо показывает два лимита сразу, и подсказка обязана назвать оба:
    /// иначе непонятно, чей процент горит красным.
    private var tooltip: String {
        guard let metrics = model.metrics else {
            return s.pick("ClaudeWeek — данных пока нет", "ClaudeWeek — no data yet")
        }
        let used = Formatting.percent(metrics.usedPercent)
        var lines = [s.pick("Неделя — \(used) из лимита", "Week — \(used) of the limit")]
        if let session = model.session {
            let spent = Formatting.percent(session.usedPercent)
            lines.append(s.pick("Сессия 5 ч — \(spent) из лимита", "5-hour session — \(spent) of the limit"))
        }
        let plan = Formatting.percent(metrics.planNowPercent)
        lines.append(s.pick("План на сейчас — \(plan)", "Plan for now — \(plan)"))
        let left = Formatting.duration(metrics.timeLeft, lang: s.lang)
        lines.append(s.pick("До сброса недели \(left)", "Week resets in \(left)"))
        return lines.joined(separator: "\n")
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
            prepareToShowPanel()
            dropdown.show(from: button)
            refresh()
        }
    }

    /// Панель открывают заново: часы подводим, а раскрытый кликом недельный
    /// ряд сворачиваем и разбивку по моделям убираем. Оба состояния живут один
    /// показ — закрывают панель щелчком мимо и по Esc, и сбросить их больше
    /// негде.
    private func prepareToShowPanel() {
        model.now = Date()
        model.expandsWeek = false
        model.showsModels = false
    }

    /// Три группы: что сделать сейчас, как программа заведена, справка и
    /// выход. Автозапуск сюда не вынесен: он такая же настройка, как остальные,
    /// и живёт строкой в окне настроек — искать её начинают там. Обновление —
    /// по той же причине: одна кнопка на вкладке «О программе», а не второе
    /// место, где то же самое состояние показывается своими словами.
    private func showMenu() {
        // Меню встаёт на то же место, что и панель, — сначала убираем её.
        dropdown.close()

        let menu = NSMenu()

        menu.addItem(withTitle: s.pick("Обновить", "Refresh"), action: #selector(refreshFromMenu), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: s.pick("Настройки…", "Settings…"), action: #selector(openConfig), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: s.pick("О программе", "About"), action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: s.pick("Выйти", "Quit"), action: #selector(quit), keyEquivalent: "q")
            .target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() { refresh() }

    @objc private func openConfig() { openSettings() }

    /// Окно настроек. Правки применяются сразу и тут же ложатся в файл —
    /// он остаётся источником правды, а окно лишь удобный способ его править.
    ///
    /// Панель при этом не закрываем, а закрепляем рядом: тему, плотность фона
    /// и скругление видно на ней самой — с настоящим размытием и своими
    /// цифрами, чего никакой предпросмотр внутри окна не покажет.
    private func openSettings() {
        if settings == nil {
            let model = SettingsModel(
                config: model.config,
                update: update,
                notifications: notifications,
                apply: { [weak self] config in self?.applyFromSettings(config) },
                check: { config in await Self.check(config: config) },
                reset: { [weak self] in self?.resetCounting() }
            )
            let controller = SettingsWindowController(model: model)
            controller.onPresent = { [weak self] in self?.pinPanel() }
            controller.onDismiss = { [weak self] in self?.dropdown.unpin() }
            settings = controller
        }
        // Окно живёт до выхода из приложения, а конфиг за это время могли
        // поправить руками — показываем то, что сейчас в файле.
        settings?.adopt(model.config)
        pinPanel()
        settings?.show(avoiding: dropdown.isShown ? dropdown.frame : nil)
    }

    private func pinPanel() {
        guard let button = statusItem.button else { return }
        prepareToShowPanel()
        dropdown.pin(from: button)
    }

    private func applyFromSettings(_ config: Config) {
        let providerChanged = config.provider != model.config.provider
            || config.timeZone != model.config.timeZone
            || config.weekStart != model.config.weekStart
            || config.workHours != model.config.workHours
            || config.weeklyBudget != model.config.weeklyBudget
        // Интервал живёт в таймере, а не в провайдере: не перезапустив таймер,
        // новый интервал ждал бы перезапуска приложения.
        let intervalChanged = config.refreshInterval != model.config.refreshInterval
        // Уведомления только что включили — спрашиваем разрешение у системы
        // здесь же: человек как раз попросил их показывать, и диалог в ответ
        // на щелчок понятен, в отличие от такого же через час.
        let notificationsEnabled = config.notifications.enabled && !model.config.notifications.enabled

        model.config = config
        update.strings = config.strings
        applyAppearance()
        render()
        if notificationsEnabled { notifications.apply(config.notifications) }

        // Ползунок шлёт по десятку изменений в секунду — на диск ходим
        // с задержкой, применяя к панели каждое сразу.
        saveTask?.cancel()
        pendingConfigWrite = config
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushConfigWrite()
        }

        guard providerChanged else {
            if intervalChanged { startTimers() }
            return
        }
        provider = ResolvingProvider(config: config)
        startTimers()
        refresh()
    }

    /// Пишет отложенную правку немедленно, если она ещё не легла на диск.
    /// Зовётся и таймером дебаунса, и `applicationWillTerminate`: выйти из
    /// приложения можно в любой момент этих 400 мс, и без досрочного сброса
    /// последняя двинутая ползунком настройка терялась бы молча.
    private func flushConfigWrite() {
        saveTask?.cancel()
        saveTask = nil
        guard let config = pendingConfigWrite else { return }
        pendingConfigWrite = nil
        do {
            try ConfigStore.save(config, to: configURL)
            // Свою же запись не перечитываем: отпечаток обновляем сразу,
            // иначе через минуту конфиг применился бы вторым заходом.
            configStamp = ConfigStamp.current(url: configURL)
        } catch {
            Log.warn("не сохранил настройки: \(error)")
        }
    }

    /// Кнопка «Начать счёт заново» из настроек: ставим отсечку по нынешнему
    /// моменту и тут же идём за свежими цифрами. Провайдер не пересоздаём —
    /// отсечку он перечитывает на каждом обходе транскриптов, а вот показать
    /// панели старый снимок после сброса было бы прямым враньём.
    private func resetCounting() {
        let account = (try? KeychainCredentials().load())?.accountMark
        do {
            try Store.resetCounting(at: Date(), account: account)
        } catch {
            Log.warn("не смог начать счёт заново: \(error)")
            return
        }
        model.snapshot = nil
        render()
        refresh()
    }

    /// Одна честная попытка сходить в официальный источник — чтобы кнопка
    /// «Проверить» в настройках отвечала не «сохранено», а «работает».
    private static func check(config: Config) async -> (String, Bool) {
        var config = config
        config.provider = .official
        do {
            let snapshot = try await ResolvingProvider(config: config).fetch()
            // Метод статический, окружения у него нет — язык берём из того же
            // конфига, с которым проверяют доступ.
            let spent = Formatting.percent(snapshot.usedPercent)
            return (config.strings.pick("получилось: \(spent) недельного лимита",
                                        "worked: \(spent) of the weekly limit"), true)
        } catch {
            let text = (error as? UsageError)?.message(config.strings.lang) ?? error.localizedDescription
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
        // Страховка к будильнику ниже: он мог не сработать вовсе — снимка на
        // момент установки не было, машина спала, часы перевели.
        if windowClosed { refresh() }
    }

    /// Окно снимка закрылось: на панели прошлая неделя.
    private var windowClosed: Bool {
        guard let window = model.snapshot?.window else { return false }
        return model.now >= window.end
    }

    /// Ставит будильник на сброс недели. Момент известен заранее — он же
    /// написан в заголовке панели, — и ждать после него очередного планового
    /// опроса незачем: человек смотрит на «100 %» уже после обнуления.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let window = model.snapshot?.window else { return }

        // Пара секунд сверху: момент сброса у сервера плавает на доли секунды,
        // и запрос ровно в него ещё застаёт прошлую неделю.
        let fire = window.end.addingTimeInterval(2)
        guard fire > Date() else { return }

        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // Часы вперёд — и сразу за числом. `tick` сам обновится только
                // если окно уже закрылось, а будильник мог прийти и мгновением
                // раньше; повторный `refresh` при этом ничего не стоит.
                self?.tick()
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil
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
        // Суточный таймер проспал вместе с машиной: её закрывают на ночь, и
        // без этого «раз в сутки» означало бы «раз в сутки работы».
        update.checkIfDue()
    }

    /// Окно недели считается в локальной таймзоне, поэтому её смена меняет
    /// и границы суток — пересчитываем целиком.
    @objc private func timeZoneChanged() {
        Log.info("сменилась системная таймзона, пересчитываю окно")
        tick()
        refresh()
    }

    /// Приложение выходит — дебаунс записи конфига (400 мс) больше нечем
    /// довести до конца: `Task.sleep` внутри него до этого момента не успеет.
    /// Без сброса здесь последняя правка ползунком, сделанная перед самым
    /// выходом («Выйти» в меню сразу после смены темы), терялась бы молча.
    @objc private func applicationWillTerminate() {
        flushConfigWrite()
    }

    private func reloadConfigIfChanged() {
        let stamp = ConfigStamp.current(url: configURL)
        guard stamp != configStamp else { return }
        configStamp = stamp

        let config = ConfigStore.load(from: configURL)
        guard config != model.config else { return }
        Log.info("конфиг изменился, применяю")
        let notificationsEnabled = config.notifications.enabled && !model.config.notifications.enabled
        model.config = config
        update.strings = config.strings
        if notificationsEnabled { notifications.apply(config.notifications) }
        settings?.adopt(config)
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
                if let self { notifications.consider(snapshot, config: model.config) }
            } catch {
                Log.warn("не смог обновить данные: \(error)")
                self?.model.apply(error: error)
            }
            self?.model.isRefreshing = false
            self?.render()
            // Окно снимка могло смениться — переставляем будильник под него.
            // Отсюда же он ставится и в первый раз: `init` заканчивается
            // обновлением, а до его ответа окна может не быть вовсе.
            self?.scheduleResetRefresh()
        }
    }
}
