import AppKit
import SwiftUI
import ClaudeWeekCore

/// Окно разбивки по моделям. Обычное окно, а не вторая панель: таблицу читают
/// глазами по строкам, её хочется оставить открытой рядом с работой, а панель
/// закрывается от первого же щелчка мимо.
///
/// Живёт от первого открытия до выхода из приложения и показывает ту же модель
/// панели — своей копии данных у него нет, поэтому цифры в нём обновляются
/// вместе с панелью, а не застывают на моменте открытия.
@MainActor
final class ModelsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PanelModel

    init(model: PanelModel) {
        self.model = model
    }

    func show() {
        if let window {
            present(window)
            return
        }

        let hosting = NSHostingController(rootView: ModelsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Расход по моделям"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ClaudeWeekModels")
        // Те же два флага, что у настроек, и по тем же причинам: окно должно
        // приходить на текущий рабочий стол и пускаться поверх полноэкранного,
        // иначе клик по проценту уносил бы человека на другой стол.
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        self.window = window

        present(window)
    }

    /// Та же уловка, что в настройках: показанное окно WindowServer держит за
    /// тем столом, где оно появилось, и снять привязку можно только сняв окно
    /// с экрана.
    private func present(_ window: NSWindow) {
        if window.isVisible && !window.isOnActiveSpace { window.orderOut(nil) }
        // Приложение живёт без Dock (`LSUIElement`) — без явной активации окно
        // откроется за спиной у той программы, в которой человек работает.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
