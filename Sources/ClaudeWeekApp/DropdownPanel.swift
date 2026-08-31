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
    /// Спрашиваем это прямо у окна, и ответ честный, потому что панель живёт на
    /// одном столе (`.moveToActiveSpace`, см. `MenuPanel`). У окна на всех
    /// столах сразу (`.canJoinAllSpaces`) такого ответа не добиться: там
    /// `isOnActiveSpace` говорит «да», пока окно видимо, на каком бы столе оно
    /// ни висело, — а список окон на экране, которым это пробовали заменить,
    /// отвечает с опозданием и не знает окна, показанного мгновение назад.
    /// Из-за той подмены панель гасила сама себя на смене стола и не
    /// закрывалась по щелчку.
    var isShown: Bool { isOpen && panel.isOnActiveSpace }

    /// Окно не убрано с экрана. Отвечает на вопрос «есть ли что закрывать»,
    /// а не «видит ли это человек» — для второго есть `isShown`.
    private var isOpen: Bool { panel.isVisible }

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

        // Панель живёт на одном столе, и переезжает она не по объявлению флага,
        // а по показу: снятое с экрана окно достаётся текущему столу, оставшееся
        // висеть — держится за прежний. Поэтому снимаем перед каждым показом.
        // Для скрытой панели это пустая операция, для своего стола — лишняя, но
        // безвредная: анимации показа нет, мигнуть нечему.
        panel.orderOut(nil)

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
        startMonitoring()
    }

    func close() {
        hiddenByDeactivation = false
        guard isOpen else { return }
        stopMonitoring()
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
        guard isPinned, isOpen else { return }
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
    /// «А мы точно ушли с её стола?» спрашиваем у самого окна: панель живёт на
    /// одном столе, и `isOnActiveSpace` отвечает на это честно. Уведомление
    /// приходит по концу перехода, но опоздание здесь уже безобидно — панель,
    /// открытую на новом столе, оно застаёт на активном столе и не трогает.
    private func observeSpaceChange() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        }
    }

    private func handleSpaceChange() {
        guard isOpen else { return }
        // Закреплённую панель держим открытой — она предпросмотр к настройкам,
        // и закрыть её значило бы отобрать то, ради чего её закрепляли.
        // Переносим на текущий стол; если приложение при этом ушло в фон,
        // её всё равно уберёт hideWhilePinned.
        if isPinned, let button = anchorButton {
            show(from: button)
            return
        }
        // Панель осталась на покинутом столе — закрываем, как системное меню.
        // Ту, что уже показана здесь, не трогаем: уведомление про переход,
        // случившийся до неё, её не касается.
        guard !panel.isOnActiveSpace else { return }
        close()
    }

    /// Верх панели — на нижней кромке строки меню, центр — под пунктом.
    /// У края экрана панель прижимается к нему, а не уезжает за границу.
    private func frame(for size: NSSize, anchor: NSWindow) -> NSRect {
        var origin = NSPoint(
            x: anchor.frame.midX - size.width / 2,
            y: anchor.frame.minY - size.height
        )
        if let screen = screen(for: anchor)?.frame {
            let margin = Theme.panelScreenMargin
            origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - size.width - margin)
            // Верхняя кромка — не выше своего экрана. Строка меню в
            // полноэкранном режиме прячется вместе со значком за верхний край,
            // и панель, приклеенная к значку, ушла бы туда же — на соседний
            // монитор, если он стоит сверху.
            origin.y = min(origin.y, screen.maxY - size.height)
            origin.y = max(origin.y, screen.minY + margin)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Экран, на строке меню которого стоит значок.
    ///
    /// `anchor.screen` на этот вопрос отвечает неверно. В полноэкранном режиме
    /// строка меню прячется, и её окно вместе со значком уезжает вверх ровно на
    /// свою высоту — за верхнюю кромку своего экрана. Стоит сверху вплотную
    /// второй монитор, и значок оказывается уже на его территории: `anchor.screen`
    /// честно отвечает «второй», панель считается от чужих границ и прижимается
    /// к его нижнему краю. Так она и висела посреди верхнего монитора, оторванная
    /// от строки меню. `NSScreen.main` на замену не годится тем более: это экран
    /// с клавиатурным фокусом, то есть чужого окна, а не нашего значка.
    ///
    /// Признак надёжнее: строка меню всегда прижата к верхней кромке своего
    /// экрана. Значит значок принадлежит тому из накрывающих его по горизонтали
    /// экранов, чья верхняя кромка к нему ближе, — и спрятанная строка меню
    /// с её сдвигом на 30 точек этого не меняет.
    private func screen(for anchor: NSWindow) -> NSScreen? {
        let icon = anchor.frame
        let covering = NSScreen.screens.filter {
            $0.frame.minX <= icon.midX && icon.midX <= $0.frame.maxX
        }
        // Значок, не влезший в строку меню, лежит левее всех экранов — по
        // горизонтали его не накрывает никто, и выбирать приходится из всех.
        return (covering.isEmpty ? NSScreen.screens : covering)
            .min { abs($0.frame.maxY - icon.maxY) < abs($1.frame.maxY - icon.maxY) }
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
        guard isOpen, let anchor else { return }
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
        guard isOpen, let anchor else { return }
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
                // Здесь спрашиваем именно «есть ли что закрывать»: панель,
                // забытую на покинутом столе, клик мимо тоже должен убирать.
                guard let self, self.isOpen else { return false }
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
        // moveToActiveSpace — панель живёт на одном столе и переезжает на
        // текущий, когда её показывают заново; fullScreenAuxiliary — чтобы её
        // пускали поверх полноэкранного окна.
        //
        // Не canJoinAllSpaces: с ним панель висит на всех столах разом, а
        // значит, едет вместе со свайпом и гаснет уже на новом столе, когда
        // приходит уведомление о переходе. Заодно он лишает окно честного
        // `isOnActiveSpace` — на нём держится весь разбор «панель здесь?».
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
