import AppKit
import SwiftUI
import ClaudeWeekCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: PanelModel
    private var provider: any UsageProvider

    init(config: Config = ConfigStore.load()) {
        model = PanelModel(config: config)
        provider = LocalProvider(config: config)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        render()
        refresh()
    }

    // MARK: Строка меню

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.image = MenuBarBar.placeholder()
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    private func render() {
        guard let button = statusItem.button else { return }

        let title = model.config.menuBarStyle == .compact ? "" : " \(model.menuBarTitle)"
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color(for: model.state),
            ]
        )

        if let snapshot = model.snapshot, let metrics = model.metrics {
            button.image = MenuBarBar.image(
                usedPercent: snapshot.usedPercent,
                planPercent: metrics.planNowPercent,
                state: metrics.state
            )
        } else {
            button.image = MenuBarBar.placeholder()
        }
        button.toolTip = tooltip
    }

    private func color(for state: LimitState) -> NSColor {
        switch state {
        case .onTrack: .labelColor
        case .overPlan: NSColor(hex: 0xFAB219)
        case .critical, .exhausted: NSColor(hex: 0xD03B3B)
        }
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
        guard let event = NSApp.currentEvent else { return togglePopover() }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.now = Date()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            refresh()
        }
    }

    private func showMenu() {
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

    @objc private func openConfig() {
        let url = ConfigStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ConfigStore.save(model.config, to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "ClaudeWeek \(ClaudeWeek.version)"
        alert.informativeText = """
        Недельный лимит Claude Code одним взглядом.
        Конфигурация: \(ConfigStore.fileURL.path)
        """
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

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
