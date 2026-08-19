import AppKit
import Observation
import UserNotifications
import ClaudeWeekCore

/// Баннеры о приближении к лимиту. Решает, о чём говорить, не сам: правила и
/// слова живут в ядре (`AlertPlanner`, `LimitAlert`), здесь остаётся общение
/// с системой — разрешение, отправка, память о сказанном на диске.
///
/// Всё, что связано с уведомлениями, идёт через один экземпляр: и панель, и
/// окно настроек смотрят на его состояние, а лог сказанного существует в
/// единственном числе — две копии разошлись бы и объявили один порог дважды.
@MainActor
@Observable
final class NotificationController {
    /// Уведомления умеет только собранный бандл: `UNUserNotificationCenter`
    /// опознаёт программу по идентификатору из Info.plist, а у бинаря,
    /// запущенного из .build отладочным `swift run`, его нет — обращение к
    /// центру там не «не работает», а роняет процесс.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Что об уведомлениях думает macOS. Нужен настройкам: включённый в
    /// программе тумблер ничего не значит, если баннеры запрещены системой,
    /// и молча гаснущие уведомления выглядели бы поломкой.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let center: UNUserNotificationCenter?
    private let delegate = BannerDelegate()
    private let logURL: URL
    private var log: AlertLog
    /// Каким контроллер показывает себя настройкам. Совпадает с `isAvailable`
    /// везде, кроме отрисовки картинок для документации: `--screenshot` идёт
    /// из отладочного бинаря, и вкладка на снимке иначе объясняла бы, почему
    /// уведомления недоступны, — при том что у собранного приложения они есть.
    private let bundled: Bool

    init(logURL: URL = Store.alertsURL, bundled: Bool = NotificationController.isAvailable) {
        self.logURL = logURL
        self.bundled = bundled
        log = Store.loadAlerts(from: logURL)
        // Центр спрашиваем только у настоящего бандла, чем бы ни было `bundled`:
        // без Info.plist обращение к нему роняет процесс.
        center = NotificationController.isAvailable ? .current() : nil
        // Без делегата macOS прячет баннер, пока программа активна, — а
        // активной она бывает ровно тогда, когда открыто окно настроек, то
        // есть в момент, когда человек жмёт «Показать пример».
        center?.delegate = delegate
    }

    // MARK: Разрешение

    /// Заводит уведомления под текущие настройки. Включённые — спрашивают
    /// разрешение (в первый раз это системный диалог), выключенные молчат:
    /// программа, спрашивающая про баннеры, которые ей запретили показывать,
    /// раздражает ровно так же, как сами баннеры.
    func apply(_ config: NotificationsConfig) {
        guard center != nil, config.enabled else { return }
        Task { await authorize() }
    }

    /// Перечитывает разрешение у системы: его меняют мимо программы, в
    /// системных настройках, и показывать вчерашнее состояние нельзя.
    func refresh() {
        guard let center else { return }
        Task { authorization = await center.notificationSettings().authorizationStatus }
    }

    /// Спрашивает разрешение, если его ещё не спрашивали. Отказ не повторяем:
    /// второй раз macOS диалога и не покажет — снять запрет можно только в
    /// системных настройках, куда и ведёт кнопка на вкладке.
    private func authorize() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
        guard authorization == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.warn("не спросил разрешение на уведомления: \(error)")
        }
        authorization = await center.notificationSettings().authorizationStatus
    }

    // MARK: Уведомления

    /// Новый снимок расхода: если он пробил порог, показываем баннер.
    /// Зовётся на каждое обновление — молчание здесь обычный исход.
    func consider(_ snapshot: UsageSnapshot, config: Config, now: Date = Date()) {
        guard center != nil else { return }

        var updated = log
        let alerts = AlertPlanner.alerts(
            for: snapshot, config: config.notifications, log: &updated, now: now
        )
        // Лог меняется и без единого баннера — на смене окна лимита, — и
        // записать это надо тоже: иначе после перезапуска программа объявит
        // прошлонедельные пороги как сегодняшние.
        if updated != log {
            log = updated
            save()
        }

        for alert in alerts {
            send(alert, config: config, now: now)
        }
    }

    /// «Показать пример» из настроек: тот же баннер, что придёт по-настоящему,
    /// с первым порогом лимита вместо живого расхода. Лога не трогает — это
    /// разговор не про расход, а про то, как он будет выглядеть.
    ///
    /// Примеров два, по одному на лимит: у недели и сессии разные заголовки,
    /// разный масштаб времени до сброса и разные пороги, и посмотреть на
    /// недельный баннер, настраивая сессию, — значит не увидеть своего.
    func preview(_ kind: AlertKind, config: Config) {
        guard center != nil else { return }
        let now = Date()
        let limit = kind == .week ? config.notifications.week : config.notifications.session
        // Момент сброса у недели настоящий, у сессии — выдуманные 72 минуты:
        // живого пятичасового окна в этот момент может не быть вовсе, а
        // подпись «сброс через …» показать надо.
        let resetsAt = kind == .week
            ? WeekWindow(containing: now, config: config).end
            : now.addingTimeInterval(72 * 60)
        let alert = LimitAlert(
            kind: kind,
            threshold: limit.first,
            percent: limit.first,
            resetsAt: resetsAt,
            isEstimate: false
        )
        Task {
            await authorize()
            send(alert, config: config, now: now)
        }
    }

    /// Баннер о вышедшей версии. О каждой говорим один раз: проверка идёт при
    /// запуске и раз в сутки, и без памяти о сказанном напоминание приходило бы
    /// каждый день, пока не обновишься.
    ///
    /// Кнопки в баннере нет намеренно: установка перезаписывает приложение и
    /// перезапускает его, а такому не место за одним щелчком из-под чужой
    /// работы. Баннер только сообщает, ставит человек — из настроек.
    func announceUpdate(_ release: Release, config: Config) {
        guard center != nil, config.notifications.update else { return }
        let version = release.version.description
        guard log.updateSaid != version else { return }

        let s = config.strings
        let content = UNMutableNotificationContent()
        content.title = s.pick("Вышла версия \(version)", "Version \(version) is out")
        content.body = s.pick("Обновиться — в настройках, вкладка «О программе»",
                              "To update, open Settings → About")
        content.threadIdentifier = "update"
        if config.notifications.sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: "update-\(version)", content: content, trigger: nil
        )
        Task {
            await authorize()
            do {
                try await center?.add(request)
                // Сказанным версия считается только после удачной отправки.
                // Пометь мы её раньше — отказ системы (нет разрешения, сбой
                // центра) навсегда съел бы новость: второй раз о ней бы уже
                // не заговорили.
                log.updateSaid = version
                save()
                Log.info("уведомление: вышла версия \(version)")
            } catch {
                Log.warn("не показал уведомление об обновлении: \(error)")
            }
        }
    }

    private func send(_ alert: LimitAlert, config: Config, now: Date) {
        guard let center else { return }

        let text = alert.message(now: now)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        // Своя нить на каждый лимит: неделя и сессия копятся в Центре
        // уведомлений двумя стопками, а не вперемешку.
        content.threadIdentifier = alert.kind.rawValue
        if config.notifications.sound { content.sound = .default }

        if let picture = AlertArtwork.png(
            percent: alert.percent,
            state: state(for: alert, config: config.notifications),
            kind: alert.kind,
            palette: config.appearance.theme.palette
        ), let attachment = try? UNNotificationAttachment(
            identifier: "ring", url: picture, options: nil
        ) {
            content.attachments = [attachment]
        }

        // Идентификатор собран из повода: пришедший дважды один и тот же
        // порог заменит прежний баннер, а не ляжет вторым. По-настоящему это
        // случается только с примером из настроек — остальное отсекают правила.
        let id = "\(alert.kind.rawValue)-\(Int(alert.threshold))-\(Int(alert.resetsAt.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        Task {
            do {
                try await center.add(request)
                // Баннер — единственное, что программа делает поверх чужой
                // работы, и в логе он должен быть виден: разбор «почему меня
                // дёрнули» начинается отсюда.
                Log.info("уведомление: \(alert.kind.rawValue) \(Formatting.percent(alert.percent)), порог \(Int(alert.threshold))")
            } catch {
                Log.warn("не показал уведомление: \(error)")
            }
        }
    }

    /// Цвет картинки — по порогам самого уведомления, а не по цветовым со
    /// вкладки «Строка меню». Иначе выходила бы нелепость: баннер о том, что
    /// расход перешагнул вашу отметку, приходил бы со спокойным зелёным
    /// числом — просто потому, что до порога окраски значка не хватило
    /// процента. Первый порог рисуется жёлтым, второй и исчерпанный лимит —
    /// красным: чем выше расход, тем тревожнее картинка.
    private func state(for alert: LimitAlert, config: NotificationsConfig) -> LimitState {
        let limit = alert.kind == .week ? config.week : config.session
        return LimitState.forPercent(alert.percent, warn: limit.first, critical: limit.second)
    }

    private func save() {
        do {
            try Store.saveAlerts(log, to: logURL)
        } catch {
            Log.warn("не сохранил историю уведомлений: \(error)")
        }
    }

    // MARK: Для настроек

    /// Состояние словами — строка на вкладке «Уведомления».
    func summary(_ s: L10n) -> String {
        guard bundled else {
            // Ровно как автозапуск и обновление: у отладочного `swift run`
            // бандла нет, и молчащие уведомления выглядели бы поломкой.
            return s.pick("""
            Доступно только у собранного приложения: отладочный swift run \
            macOS не считает программой и уведомления от него не принимает.
            """, """
            Only available to a built app: macOS does not consider a debug \
            swift run an application and accepts no notifications from it.
            """)
        }
        return switch authorization {
        case .notDetermined:
            s.pick("macOS спросит разрешение, когда программа соберётся показать первый баннер.",
                   "macOS will ask for permission when the app is about to show its first banner.")
        case .denied:
            s.pick("""
            macOS не пропускает уведомления ClaudeWeek. Разрешить их можно \
            только в системных настройках — кнопка ниже.
            """, """
            macOS is blocking ClaudeWeek notifications. They can only be allowed \
            in System Settings — the button below.
            """)
        case .authorized:
            s.pick("macOS пропускает уведомления.", "macOS lets notifications through.")
        case .provisional:
            s.pick("macOS пропускает уведомления тихо: без звука и сразу в Центр уведомлений.",
                   "macOS delivers notifications quietly: no sound, straight to Notification Centre.")
        case .ephemeral:
            s.pick("Уведомления разрешены на время этого сеанса.",
                   "Notifications are allowed for this session only.")
        @unknown default:
            s.pick("Состояние разрешения macOS неизвестно.", "The macOS permission state is unknown.")
        }
    }

    /// Показывать ли кнопку «Открыть настройки macOS»: только когда запрет
    /// снимается там и больше нигде.
    var needsSystemSettings: Bool {
        bundled && authorization == .denied
    }

    /// Работает ли кнопка «Показать пример»: у неотличимого от программы
    /// бинаря показывать нечем.
    var canPreview: Bool { bundled }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.notifications"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Показывает баннер, даже когда ClaudeWeek — активная программа. По
/// умолчанию macOS такие уведомления придерживает, считая, что человек и так
/// смотрит в окно; у виджета строки меню это ровно наоборот — окно настроек
/// открыто как раз затем, чтобы уведомления настроить.
private final class BannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
