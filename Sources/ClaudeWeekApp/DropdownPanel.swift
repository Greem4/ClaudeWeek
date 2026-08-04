import AppKit
import SwiftUI

/// Выпадающая панель в форме системного меню: без стрелки-хвостика, верхней
/// кромкой вплотную к строке меню, фон — материал меню, появление мгновенное.
///
/// NSPopover ничего из этого не умеет: стрелку у него не убрать, от строки он
/// отступает на её высоту, окно рисует своим непрозрачным фоном и открывается
/// с анимацией. Поэтому окно своё.
@MainActor
final class DropdownPanel {
    private let panel = MenuPanel()
    private let effect = NSVisualEffectView()
    private let hosting = SizingHostingView(rootView: AnyView(EmptyView()))
    private var monitors: [Any] = []
    /// Окно пункта строки меню — от него считаем место панели и по нему же
    /// узнаём «свой» клик.
    private weak var anchor: NSWindow?

    var isShown: Bool { panel.isVisible }

    init() {
        // .menu — тот же материал, что под системными меню строки: тёмная
        // полупрозрачная подложка с размытием того, что под ней. Состояние
        // .active, иначе панель тускнеет вместе с неактивным приложением,
        // а оно у нас неактивно почти всегда.
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.panelCornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        hosting.onFittingSizeChange = { [weak self] size in
            self?.resize(to: size)
        }
    }

    /// Тон кладём здесь, а не в самой панели недели: тот же вид уходит в
    /// `--screenshot`, где фон рисуется свой и вуаль только мешала бы.
    func setContent(_ view: some View) {
        hosting.rootView = AnyView(view.background(Theme.panelTint))
    }

    // MARK: Показ и скрытие

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        guard let anchor = button.window else { return }
        self.anchor = anchor

        hosting.layoutSubtreeIfNeeded()
        panel.setFrame(frame(for: hosting.fittingSize, anchor: anchor), display: false)
        panel.makeKeyAndOrderFront(nil)
        // Тень строится по непрозрачным пикселям контента, а он только что
        // сменил размер — иначе от прошлого показа останется старый контур.
        panel.invalidateShadow()
        startMonitoring()
    }

    func close() {
        guard panel.isVisible else { return }
        stopMonitoring()
        panel.orderOut(nil)
    }

    /// Верх панели — на нижней кромке строки меню, центр — под пунктом.
    /// У края экрана панель прижимается к нему, а не уезжает за границу.
    private func frame(for size: NSSize, anchor: NSWindow) -> NSRect {
        var origin = NSPoint(
            x: anchor.frame.midX - size.width / 2,
            y: anchor.frame.minY - size.height
        )
        if let screen = (anchor.screen ?? NSScreen.main)?.frame {
            let margin = Theme.panelScreenMargin
            origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - size.width - margin)
            origin.y = max(origin.y, screen.minY + margin)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Содержимое меняет высоту на ходу: приходят данные, появляется строка
    /// сессии или прогноз исчерпания. Растём вниз — верхняя кромка приклеена
    /// к строке меню и дёргаться не должна.
    private func resize(to size: NSSize) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Закрытие по клику мимо

    private func startMonitoring() {
        stopMonitoring()

        // Клик в чужом приложении. Слежка за мышью, в отличие от клавиатуры,
        // разрешения «Универсального доступа» не требует.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        // Свои окна. Клик по самому пункту строки меню пропускаем: там
        // сработает toggle, а закрой мы панель здесь — она бы тут же
        // открылась заново и клик перестал бы её закрывать.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            // Из MainActor.assumeIsolated возвращаем только Bool: NSEvent
            // не Sendable, и через границу изоляции его не отдать.
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isShown else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }  // Esc
                    self.close()
                    return true
                }
                guard event.window !== self.panel, event.window !== self.anchor else { return false }
                self.close()
                return false
            }
            return swallow ? nil : event
        }

        monitors = [global, local].compactMap { $0 }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Окно панели: без рамки и без активации приложения — как у системных меню.
private final class MenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Уровень меню: панель не должна нырять под чужие окна, в том числе
        // полноэкранные.
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Появление и скрытие без анимации: панель нужна по клику сразу.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// Без этого borderless-окно не принимает клавиатуру, и Esc до нас
    /// не доходит.
    override var canBecomeKey: Bool { true }
}

/// NSHostingView не двигает окно, когда SwiftUI меняет высоту содержимого, —
/// сообщаем новый размер наружу, иначе строка сессии или прогноз обрежутся.
private final class SizingHostingView: NSHostingView<AnyView> {
    var onFittingSizeChange: ((NSSize) -> Void)?
    private var reported: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        // Сравнение с прошлым размером обрывает петлю: смена размера окна
        // приводит сюда же следующим проходом.
        guard size.width > 0, size.height > 0, size != reported else { return }
        reported = size
        onFittingSizeChange?(size)
    }
}
