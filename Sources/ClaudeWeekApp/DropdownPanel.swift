import AppKit
import SwiftUI
import ClaudeWeekCore

/// Выпадающая панель в форме системного меню: без стрелки-хвостика, верхней
/// кромкой вплотную к строке меню, фон — материал меню, появление мгновенное.
///
/// NSPopover ничего из этого не умеет: стрелку у него не убрать, от строки он
/// отступает на её высоту, окно рисует своим непрозрачным фоном и открывается
/// с анимацией. Поэтому окно своё.
@MainActor
final class DropdownPanel {
    private let panel = MenuPanel()
    /// Корневой слой окна: он несёт скругление, обводку и маску. Материал
    /// лежит внутри и может быть выключен — форма панели от этого не зависит.
    private let container = BorderedView()
    private let effect = NSVisualEffectView()
    private let hosting = SizingHostingView(rootView: AnyView(EmptyView()))
    private var monitors: [Any] = []
    /// Окно пункта строки меню — от него считаем место панели и по нему же
    /// узнаём «свой» клик.
    private weak var anchor: NSWindow?
    /// Сам пункт строки меню: по нему панель показывается заново, когда
    /// возвращаемся в приложение с открытыми настройками.
    private weak var anchorButton: NSStatusBarButton?

    /// Закреплённая панель не закрывается по клику мимо — так себя ведёт
    /// живой предпросмотр при открытых настройках.
    private var isPinned = false
    /// Панель убрана не человеком, а уходом в другое приложение, — значит,
    /// на возврате её надо показать снова.
    private var hiddenByDeactivation = false
    private var activationObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Панель показана — и показана здесь, на текущем столе.
    ///
    /// «Здесь» тут не вычисляется, а обеспечивается: панель закрывается на
    /// смене стола (`handleSpaceChange`), поэтому видимая панель всегда на том
    /// столе, где её открыли.
    ///
    /// Спрашивать это у системы не выходит — пробовали дважды, оба признака
    /// врут. `isOnActiveSpace` у окна с `.canJoinAllSpaces` отвечает «да», пока
    /// окно видимо, на каком бы столе оно ни висело. Список окон на экране
    /// (`CGWindowListCopyWindowInfo` с `.optionOnScreenOnly`) отвечает с
    /// опозданием: только что показанного окна в нём ещё нет, и панель гасла
    /// сама — смена стола заставала её «не на экране» через секунду после
    /// появления, — а клик по пункту меню читался как «показать» вместо
    /// «закрыть» и лишь перемигивал её.
    var isShown: Bool { panel.isVisible }

    /// Когда панель показали в последний раз. Нужно `handleSpaceChange`,
    /// чтобы отличить запоздавшее уведомление от настоящего ухода на другой стол.
    private var shownAt: Date?

    /// Насколько свежий показ считается «только что». Уведомление о смене стола
    /// приходит по концу перехода — к этому моменту человек уже видит новый стол
    /// и успевает щёлкнуть по пункту меню, так что уведомление приходит вдогонку
    /// за показом. Секунды хватает: переход занимает заметно меньше.
    private static let freshShow: TimeInterval = 1

    var frame: NSRect { panel.frame }

    init() {
        // Материал строки меню: полупрозрачная подложка с размытием того,
        // что под ней. Состояние .active, иначе панель тускнеет вместе с
        // неактивным приложением, а оно у нас неактивно почти всегда.
        effect.blendingMode = .behindWindow
        effect.state = .active

        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1

        for view in [effect, hosting] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        panel.contentView = container
        apply(appearance: AppearanceConfig(), palette: .system)

        hosting.onFittingSizeChange = { [weak self] size in
            self?.resize(to: size)
        }
        observeSpaceChange()
        observeResize()
        observeScreenChange()
    }

    func setContent(_ view: some View) {
        hosting.rootView = AnyView(view)
    }

    /// Настройки вида. Вуаль поверх материала рисует сама панель недели
    /// (`PopoverView.backdrop`) — здесь только то, чем владеет окно:
    /// материал, скругление, обводка и режим прозрачности.
    func apply(appearance: AppearanceConfig, palette: Palette) {
        effect.material = palette.material.nsMaterial
        // Непрозрачный режим: материал гасим, фон рисует SwiftUI сплошным
        // цветом палитры. Оставить материал под ним значило бы платить за
        // размытие, которого не видно.
        effect.isHidden = !appearance.transparentPanel
        container.layer?.cornerRadius = appearance.cornerRadius
        container.borderInk = palette.border
        container.applyBorderColor()
        panel.invalidateShadow()
    }

    // MARK: Показ и скрытие

    func show(from button: NSStatusBarButton) {
        guard let anchor = button.window else { return }
        self.anchor = anchor
        anchorButton = button
        hiddenByDeactivation = false

        hosting.layoutSubtreeIfNeeded()

        // Рабочий стол, на котором окно показали, WindowServer запоминает за
        // ним, и полноэкранное пространство держит его особенно крепко:
        // показанное поверх фильма, дальше оно так и остаётся там — на других
        // столах панели нет, а попытка вывести её туда лишь перекидывает
        // экран обратно к плееру. Снятие с экрана эту привязку отпускает,
        // и следующий показ достаётся текущему столу. Отличить «свой» стол от
        // чужого нельзя, поэтому `orderOut` делаем безусловно, когда панель уже
        // видима, — лишний для своего стола, но безвредный: анимации показа нет.
        if isShown { panel.orderOut(nil) }

        panel.setFrame(frame(for: hosting.fittingSize, anchor: anchor), display: false)
        // orderFrontRegardless, а не makeKeyAndOrderFront: приложение живёт
        // без Dock и почти всегда неактивно, а неактивному makeKey сначала
        // ищет окну «своё» пространство — ровно то, от чего мы уходим.
        panel.orderFrontRegardless()
        // Ключевой панель делаем уже показанной на этом столе — ради Esc,
        // который ловится только окном с клавиатурным фокусом. Закреплённой
        // фокус не нужен и вреден: Esc её всё равно не закрывает (мониторы
        // выключены), а отбирать клавиатуру у окна настроек, ради которого её
        // и закрепили, значит ломать в нём ⌘W и переходы по Tab.
        if !isPinned { panel.makeKey() }
        // Тень строится по непрозрачным пикселям контента, а он только что
        // сменил размер — иначе от прошлого показа останется старый контур.
        panel.invalidateShadow()
        shownAt = Date()
        startMonitoring()
    }

    func close() {
        hiddenByDeactivation = false
        guard isShown else { return }
        stopMonitoring()
        shownAt = nil
        panel.orderOut(nil)
    }

    // MARK: Закрепление на время настроек

    /// Держать панель открытой, пока правят настройки: иначе первый же клик
    /// по ползунку убирал бы ровно то, ради чего его крутят.
    func pin(from button: NSStatusBarButton) {
        isPinned = true
        // Мониторы кликов панели больше не нужны: закрывать её теперь
        // некому, кроме самого окна настроек.
        stopMonitoring()
        observeActivation()
        if !isShown { show(from: button) } else { anchorButton = button }
    }

    func unpin() {
        isPinned = false
        stopObservingActivation()
        close()
    }

    /// Панель живёт на уровне меню и висела бы поверх чужих окон, стоит уйти
    /// из настроек в другую программу. Уходим вместе с приложением
    /// и возвращаемся вместе с ним же.
    private func observeActivation() {
        stopObservingActivation()
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideWhilePinned() }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreWhilePinned() }
            },
        ]
    }

    private func stopObservingActivation() {
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers = []
    }

    private func hideWhilePinned() {
        guard isPinned, isShown else { return }
        panel.orderOut(nil)
        hiddenByDeactivation = true
    }

    private func restoreWhilePinned() {
        // Панель, закрытую человеком (клик по пункту меню), обратно не тянем:
        // возвращаем только то, что убрали сами.
        guard isPinned, hiddenByDeactivation, let button = anchorButton else { return }
        show(from: button)
    }

    // MARK: Смена рабочего стола

    /// Ушли на другой стол — панель остаётся на прежнем. Системное меню в
    /// такой ситуации просто закрывается, и мы делаем то же: брошенное окно
    /// не только висит невидимкой, но и тянет привязку к чужому пространству
    /// на следующий показ.
    ///
    /// «А мы точно ушли с её стола?» у системы не спрашиваем — честного ответа
    /// она не даёт (см. `isShown`). Вместо этого закрываем на каждой смене
    /// стола, отсеивая по времени показа единственный случай, где это было бы
    /// неверно: уведомление приходит по концу перехода и может обогнать клик,
    /// которым панель только что открыли на новом столе.
    private func observeSpaceChange() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        }
    }

    private func handleSpaceChange() {
        guard isShown else { return }
        // Закреплённую панель держим открытой — она предпросмотр к настройкам,
        // и закрыть её значило бы отобрать то, ради чего её закрепляли.
        // Переносим на текущий стол; если приложение при этом ушло в фон,
        // её всё равно уберёт hideWhilePinned.
        if isPinned, let button = anchorButton {
            show(from: button)
            return
        }
        // Панель, показанная мгновение назад, — это панель, открытая уже здесь:
        // уведомление про переход, который случился до неё, и её не касается.
        if let shownAt, Date().timeIntervalSince(shownAt) < Self.freshShow { return }
        close()
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
    /// сессии или прогноза, раскрывается недельный ряд. Растём вниз — верхняя
    /// кромка приклеена к строке меню и дёргаться не должна.
    ///
    /// Поэтому место считается заново от пункта строки меню, а не от
    /// собственной рамки окна. Своя рамка для этого не годится: сразу после
    /// `setFrame` она ещё отдаёт прежнюю высоту — новую досчитывает Auto Layout
    /// следующим проходом, — и отсчёт верха как `maxY` уводил панель вниз ровно
    /// на разницу высот. Одна строка сессии смещала её незаметно, раскрытая
    /// неделя отрывала от строки меню на шесть строк.
    private func resize(to size: NSSize) {
        guard isShown, let anchor else { return }
        panel.setFrame(frame(for: size, anchor: anchor), display: true)
        pinToAnchor()
    }

    /// Возвращает верхнюю кромку под строку меню, не трогая размер.
    ///
    /// Высоту окна в конце концов назначает Auto Layout хостинга, и наш
    /// `setFrame` он переигрывает: размер применяется следующим проходом, а
    /// положение остаётся наше — посчитанное под другую высоту. Окно и
    /// оказывалось ниже строки меню ровно на разницу высот (а свёрнутое —
    /// выше, за верхним краем экрана). Поэтому кромку правим по факту: на
    /// каждое изменение размера, от кого бы оно ни пришло, и по уже
    /// применённой высоте, а не по той, которую мы просили.
    private func pinToAnchor() {
        guard isShown, let anchor else { return }
        let target = frame(for: panel.frame.size, anchor: anchor).origin
        guard target != panel.frame.origin else { return }
        panel.setFrameOrigin(target)
        panel.invalidateShadow()
    }

    private func observeResize() {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToAnchor() }
        }
    }

    /// Монитор отключили, разрешение сменили или строку меню отодвинула
    /// Notch/Dock — `anchor.frame` подхватывает новое место сама (WindowServer
    /// двигает окно пункта строки меню), а вот панель без этой подписки
    /// оставалась бы висеть там, где её открыли. Незакреплённую это не сильно
    /// заботит: следующий клик мимо или показ пересчитает место сам, — но
    /// закреплённая (открыты настройки) живёт на экране произвольно долго и
    /// пересчёта дожидается только отсюда.
    private func observeScreenChange() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToAnchor() }
        }
    }

    // MARK: Закрытие по клику мимо

    private func startMonitoring() {
        stopMonitoring()
        guard !isPinned else { return }

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

/// Корень окна с обводкой. Красим её сами: цвет слоя, в отличие от NSColor,
/// при смене темы не пересчитывается — ловим смену и красим заново.
private final class BorderedView: NSView {
    var borderInk: Ink = Palette.system.border

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = borderInk.nsColor.cgColor
        }
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
        // canJoinAllSpaces — чтобы панель приходила на текущий рабочий стол,
        // fullScreenAuxiliary — чтобы её пускали поверх полноэкранного окна.
        // Одних флагов мало: показанное окно всё равно остаётся привязанным
        // к своему столу, и это разбирается в `show(from:)`.
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
