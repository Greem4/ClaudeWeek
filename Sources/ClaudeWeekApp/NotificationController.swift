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
    /// с первым недельным порогом вместо живого расхода. Лога не трогает —
    /// это разговор не про расход, а про то, как он будет выглядеть.
    func preview(config: Config) {
        guard center != nil else { return }
        let now = Date()
        let alert = LimitAlert(
            kind: .week,
            threshold: config.notifications.week.first,
            percent: config.notifications.week.first,
            resetsAt: WeekWindow(containing: now, config: config).end,
            isEstimate: false
        )
        Task {
            await authorize()
            send(alert, config: config, now: now)
        }
    }

    private func send(_ alert: LimitAlert, config: Config, now: Date) {
        guard let center else { return }

        let text = alert.message(now: now, calendar: config.calendar)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        // Своя нить на каждый лимит: неделя и сессия копятся в Центре
        // уведомлений двумя стопками, а не вперемешку.
        content.threadIdentifier = alert.kind.rawValue
        if config.notifications.sound { content.sound = .default }

        if let picture = AlertArtwork.png(
            percent: alert.percent,
            state: state(for: alert, thresholds: config.thresholds),
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
            } catch {
                Log.warn("не показал уведомление: \(error)")
            }
        }
    }

    /// Цвет кольца на картинке — по тем же порогам, что красят значок в
    /// строке меню, а не по порогу уведомления: иначе баннер и значок
    /// показывали бы один и тот же расход разными цветами.
    private func state(for alert: LimitAlert, thresholds: Thresholds) -> LimitState {
        switch alert.kind {
        case .week:
            LimitState.forPercent(
                alert.percent, warn: thresholds.weekWarn, critical: thresholds.weekCritical
            )
        case .session:
            LimitState.forPercent(
                alert.percent, warn: thresholds.sessionWarn, critical: thresholds.sessionCritical
            )
        }
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
    var summary: String {
        guard bundled else {
            // Ровно как автозапуск и обновление: у отладочного `swift run`
            // бандла нет, и молчащие уведомления выглядели бы поломкой.
            return """
            Доступно только у собранного приложения: отладочный swift run \
            macOS не считает программой и уведомления от него не принимает.
            """
        }
        return switch authorization {
        case .notDetermined:
            "macOS спросит разрешение, когда программа соберётся показать первый баннер."
        case .denied:
            """
            macOS не пропускает уведомления ClaudeWeek. Разрешить их можно \
            только в системных настройках — кнопка ниже.
            """
        case .authorized:
            "macOS пропускает уведомления."
        case .provisional:
            "macOS пропускает уведомления тихо: без звука и сразу в Центр уведомлений."
        case .ephemeral:
            "Уведомления разрешены на время этого сеанса."
        @unknown default:
            "Состояние разрешения macOS неизвестно."
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
