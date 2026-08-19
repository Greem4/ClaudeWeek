import Foundation

/// Пороги уведомлений одного лимита: два процента, после которых о расходе
/// стоит сказать вслух. Два, а не лестница произвольной длины, — потому что
/// уведомление ценно ровно до тех пор, пока его читают: первое застаёт, когда
/// ещё можно перепланировать день, второе — когда пора закругляться. Третье
/// между ними ничего не добавляет, зато приучает смахивать баннеры не глядя.
///
/// Живут отдельно от `Thresholds`: те красят значок и панель, эти дёргают
/// человека. Совпадать они не обязаны — цвет можно замечать на 81 %, а
/// разговаривать с собой только на 95 %.
public struct LimitNotifications: Codable, Sendable, Equatable {
    /// Уведомления по этому лимиту. Выключенный — молчит, пороги при этом
    /// остаются на месте: тумблером пользуются, чтобы переждать неделю, а не
    /// чтобы забыть настроенные числа.
    public var enabled: Bool
    /// Первый порог: «пора приглядывать».
    public var first: Double
    /// Второй: «дальше некуда».
    public var second: Double

    public init(enabled: Bool = true, first: Double, second: Double) {
        self.enabled = enabled
        self.first = first
        self.second = second
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LimitNotifications(first: 80, second: 95)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            first: try c.decodeIfPresent(Double.self, forKey: .first) ?? d.first,
            second: try c.decodeIfPresent(Double.self, forKey: .second) ?? d.second
        )
    }

    /// Пороги в том порядке, в каком их пробивает расход. Совпавшие
    /// схлопываются в один: два одинаковых числа — это один порог, о котором
    /// иначе сказали бы дважды.
    public var points: [Double] {
        guard enabled else { return [] }
        let pair = [min(first, second), max(first, second)]
        return pair[0] == pair[1] ? [pair[0]] : pair
    }

    /// Самый высокий из уже пройденных порогов; nil — ни одного.
    /// Берётся включительно: настроенные 80 % срабатывают ровно на 80 %,
    /// а не на 80,1 — так же, как читает шкалу человек и как красит `LimitState`.
    public func reached(_ percent: Double) -> Double? {
        points.filter { percent >= $0 }.max()
    }

    /// Порог 0 % означал бы уведомление на пустом месте, поэтому шкала
    /// начинается с единицы. Порядок чиним молча, как и везде в конфиге.
    ///
    /// Вывернутую пару переставляем, а не подтягиваем верхнюю границу к
    /// нижней, как это делают цветовые `Thresholds`: там роли жёстко привязаны
    /// к цветам, а здесь два числа — просто две отметки по дороге к лимиту, и
    /// написавший «95 и 80» хотел два порога, а не один на 95.
    public func validated() -> LimitNotifications {
        var n = self
        let d = LimitNotifications(first: 80, second: 95)
        if !(1...100).contains(n.first) { n.first = d.first }
        if !(1...100).contains(n.second) { n.second = d.second }
        if n.second < n.first { swap(&n.first, &n.second) }
        return n
    }
}

/// Уведомления целиком: общий выключатель и по набору порогов на каждый лимит.
///
/// Недельный и пятичасовой ходят раздельно намеренно. В сессию упираются чаще,
/// а стоит это полчаса ожидания; неделя упирается реже, но до конца недели.
/// Один набор порогов на оба означал бы либо молчание там, где важно, либо
/// баннер каждые пять часов.
public struct NotificationsConfig: Codable, Sendable, Equatable {
    /// Общий выключатель: гасит оба лимита разом, не трогая их настройки.
    public var enabled: Bool
    /// Звук вместе с баннером. Выключенный — уведомление приходит молча и
    /// ждёт в Центре уведомлений.
    public var sound: Bool
    public var week: LimitNotifications
    public var session: LimitNotifications

    /// Недельные пороги выше сессионных: неделя не сбросится до конца недели,
    /// и предупреждать о ней надо раньше, чем о пятичасовом окне, которое
    /// само отпустит через считаные часы.
    public init(
        enabled: Bool = true,
        sound: Bool = true,
        week: LimitNotifications = LimitNotifications(first: 80, second: 95),
        session: LimitNotifications = LimitNotifications(first: 75, second: 95)
    ) {
        self.enabled = enabled
        self.sound = sound
        self.week = week
        self.session = session
    }

    // Как и во всём конфиге: каждый ключ необязателен, недостающее берётся
    // из дефолтов. Конфиг версии без уведомлений — обычный случай, а не сбой.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationsConfig()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            sound: try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound,
            week: try c.decodeIfPresent(LimitNotifications.self, forKey: .week) ?? d.week,
            session: try c.decodeIfPresent(LimitNotifications.self, forKey: .session) ?? d.session
        )
    }

    public func validated() -> NotificationsConfig {
        var n = self
        n.week = n.week.validated()
        n.session = n.session.validated()
        return n
    }
}

/// Какой лимит просит слова.
public enum AlertKind: String, Codable, Sendable {
    case week
    case session
}

/// Один повод показать баннер: лимит, пробитый порог и то, что о нём сказать.
/// Само уведомление отсюда не отправляется — это делает слой приложения:
/// ядро остаётся без единого импорта UI и проверяется тестами.
public struct LimitAlert: Sendable, Equatable {
    public let kind: AlertKind
    /// Порог, который пробили, — 80, 95 и так далее.
    public let threshold: Double
    /// Сколько потрачено на самом деле: расход перешагивает порог, а не встаёт
    /// на него, и в тексте честнее живое число.
    public let percent: Double
    /// Когда лимит отпустит.
    public let resetsAt: Date
    /// Расход посчитан на месте, а не назван сервером, — в тексте это знак ≈.
    public let isEstimate: Bool
    /// С какого момента идёт окно этого лимита: у недели — её начало, у сессии
    /// — пять часов назад от сброса. Отвечает на «а с какого дня это
    /// накапало», которое по одному проценту не прочитать.
    public let startedAt: Date?
    /// Модель, на которую в этом окне ушло больше всего. У недели берётся из
    /// снимка, у сессии её пока нет: разбивка считается за недельное окно, и
    /// показать недельную долю в баннере о пятичасовом лимите значило бы
    /// назвать чужое число своим.
    public let topModel: ModelUsage?

    public init(
        kind: AlertKind,
        threshold: Double,
        percent: Double,
        resetsAt: Date,
        isEstimate: Bool,
        startedAt: Date? = nil,
        topModel: ModelUsage? = nil
    ) {
        self.kind = kind
        self.threshold = threshold
        self.percent = percent
        self.resetsAt = resetsAt
        self.isEstimate = isEstimate
        self.startedAt = startedAt
        self.topModel = topModel
    }

    public var isExhausted: Bool { percent >= 100 }

    /// Тот же повод, но с досчитанной моделью. Нужен слою приложения: разбивку
    /// за пятичасовое окно считает провайдер, а он ядру не виден.
    public func with(topModel: ModelUsage?) -> LimitAlert {
        LimitAlert(
            kind: kind,
            threshold: threshold,
            percent: percent,
            resetsAt: resetsAt,
            isEstimate: isEstimate,
            startedAt: startedAt,
            topModel: topModel ?? self.topModel
        )
    }

    /// Две строки баннера. Живут в ядре вместе с правилами: слова — такая же
    /// часть уведомления, как момент его отправки, и проверяются теми же
    /// тестами.
    ///
    /// Первая, полужирная, отвечает на единственный вопрос «сколько уже
    /// потрачено», вторая — «сколько ждать». Больше в баннере не нужно
    /// ничего: третья строка переносилась бы и превращала его в кашу.
    ///
    /// Какой это лимит, говорит не текст, а картинка справа: пятичасовая
    /// сессия приходит дугой, недельный лимит — числом. Тот же язык, что в
    /// строке меню, где дуга по умолчанию отдана сессии, а цифра — неделе.
    ///
    /// Часа на циферблате здесь нет намеренно: «через 2 часа 56 минут» и
    /// «в воскресенье в 2:10» — одно и то же, сказанное дважды. Точный момент
    /// сброса по-прежнему стоит в панели, где на него смотрят осознанно.
    /// Порога нет по той же причине: человек его сам и задал.
    ///
    /// Третья строка — статистика этого окна: с какого дня оно идёт и на какую
    /// модель ушло больше всего. Она нужна там, где картинку не показывают
    /// вовсе (Центр уведомлений в компактном виде, запрет вложений), и
    /// повторяет то же, что нарисовано на полосе.
    public func message(
        now: Date,
        lang: Lang = .ru,
        calendar: Calendar = .current
    ) -> (title: String, body: String) {
        let l = L10n(lang)
        let spent = (isEstimate ? "≈" : "") + Formatting.percent(percent)
        let title = isExhausted
            ? l.pick("Лимит исчерпан", "Limit reached")
            : l.pick("Израсходовано \(spent)", "\(spent) used")
        let left = Formatting.longDuration(resetsAt.timeIntervalSince(now), lang: lang)
        var body = l.pick("Сброс через \(left)", "Resets in \(left)")
        if let stats = statistics(lang: lang, calendar: calendar) {
            body += "\n" + stats
        }
        return (title, body)
    }

    /// «Неделя с СБ», «Сессия с 17:30». nil — начала окна не знаем, и сказать
    /// нечего: «неделя с ?» хуже молчания.
    ///
    /// У недели опора — день: «с СБ» человек сопоставляет с рядом суток на
    /// панели. У пятичасовой сессии день не значит ничего (она вся внутри
    /// одного), и опора у неё — час начала.
    public func windowLabel(lang: Lang = .ru, calendar: Calendar = .current) -> String? {
        guard let startedAt else { return nil }
        let l = L10n(lang)
        let since = kind == .week
            ? Formatting.weekdayShort(startedAt, calendar: calendar, lang: lang)
            : Formatting.clock(startedAt, calendar: calendar)
        return kind == .week
            ? l.pick("Неделя с \(since)", "Week since \(since)")
            : l.pick("Сессия с \(since)", "Session since \(since)")
    }

    /// «больше всего Opus 62 %». nil — разбивки нет: у сессии её могли не
    /// досчитать, а у пустого окна и считать нечего.
    public func modelLabel(lang: Lang = .ru) -> String? {
        guard let topModel, topModel.sharePercent > 0 else { return nil }
        let share = Formatting.percent(topModel.sharePercent)
        return L10n(lang).pick("больше всего \(topModel.title(lang)) \(share)",
                               "mostly \(topModel.title(lang)) \(share)")
    }

    /// Обе половины одной строкой — для текста баннера.
    public func statistics(lang: Lang = .ru, calendar: Calendar = .current) -> String? {
        guard let window = windowLabel(lang: lang, calendar: calendar) else { return nil }
        guard let model = modelLabel(lang: lang) else { return window }
        return "\(window) · \(model)"
    }
}

/// Что уже сказано — чтобы не повторяться. Лежит на диске рядом с кешем:
/// приложение перезапускают чаще, чем сбрасывается недельный лимит (обновление,
/// перезагрузка, выход из системы), и без записи каждый запуск заново
/// объявлял бы про те же 80 %.
public struct AlertLog: Codable, Sendable, Equatable {
    /// Окно, к которому относится сказанное про неделю. Сменилось — начинаем
    /// молчать заново: это уже другая неделя, и её 80 % будут своими.
    public var weekEnd: Date?
    /// Самый высокий порог недели, о котором уже сказали в этом окне.
    public var weekSaid: Double?
    /// То же для пятичасовой сессии; её окно сменяется несколько раз в сутки.
    public var sessionEnd: Date?
    public var sessionSaid: Double?
    /// Когда показали последний баннер — на нём держится остывание.
    public var lastSentAt: Date?

    public init(
        weekEnd: Date? = nil,
        weekSaid: Double? = nil,
        sessionEnd: Date? = nil,
        sessionSaid: Double? = nil,
        lastSentAt: Date? = nil
    ) {
        self.weekEnd = weekEnd
        self.weekSaid = weekSaid
        self.sessionEnd = sessionEnd
        self.sessionSaid = sessionSaid
        self.lastSentAt = lastSentAt
    }
}

/// Правила, по которым снимок превращается в баннеры. Ровно три, и все три —
/// про то, как не стать источником шума:
///
/// 1. только на ухудшении: расход, откатившийся назад, молчит;
/// 2. об одном пороге — один раз за окно лимита;
/// 3. остывание: два баннера подряд не ближе, чем через `cooldown`.
///
/// Чистая функция над `AlertLog`: ей незачем знать ни про UNUserNotificationCenter,
/// ни про главный актор, и потому её целиком гоняют тесты.
public enum AlertPlanner {
    /// Остывание между показами. Пять минут — меньше самого короткого разумного
    /// интервала опроса и заметно больше времени, за которое расход успевает
    /// перешагнуть оба порога сразу: пачки баннеров не будет, а важное
    /// не задержится дольше одного круга обновления.
    public static let cooldown: TimeInterval = 300

    /// Что показать по этому снимку. `log` правится на месте — вызывающему
    /// остаётся положить его на диск.
    ///
    /// Пустой ответ означает «молчим», а не «ошибка»: это обычное состояние
    /// девяноста девяти обновлений из ста.
    public static func alerts(
        for snapshot: UsageSnapshot,
        config: NotificationsConfig,
        log: inout AlertLog,
        now: Date = Date()
    ) -> [LimitAlert] {
        // Выключенные уведомления лога не трогают: включив их назавтра, человек
        // ждёт разговора про сегодняшний расход, а не про то, что он «уже был
        // объявлен», пока баннеры молчали.
        guard config.enabled else { return [] }

        var due: [LimitAlert] = []

        // Неделя. Окно берётся из самого снимка: при живом сервере это его
        // `resets_at`, офлайн — граница, посчитанная по конфигу.
        let weekEnd = snapshot.window.end
        if log.weekEnd != weekEnd {
            log.weekEnd = weekEnd
            log.weekSaid = nil
        }
        if let point = config.week.reached(snapshot.usedPercent),
           point > (log.weekSaid ?? 0) {
            due.append(
                LimitAlert(
                    kind: .week,
                    threshold: point,
                    percent: snapshot.usedPercent,
                    resetsAt: weekEnd,
                    isEstimate: snapshot.isEstimate,
                    startedAt: snapshot.window.start,
                    // Разбивка уже отсортирована от дорогого к дешёвому —
                    // первая строка и есть та модель, на которую ушло больше
                    // всего.
                    topModel: snapshot.byModel.first
                )
            )
        }

        // Сессия. Истёкшая молчит: от её процента после сброса не остаётся
        // ничего, и объявлять по нему 95 % значило бы будить человека прошлым.
        if let session = snapshot.session, session.isFresh(at: now) {
            if log.sessionEnd != session.resetsAt {
                log.sessionEnd = session.resetsAt
                log.sessionSaid = nil
            }
            if let point = config.session.reached(session.usedPercent),
               point > (log.sessionSaid ?? 0) {
                due.append(
                    LimitAlert(
                        kind: .session,
                        threshold: point,
                        percent: session.usedPercent,
                        resetsAt: session.resetsAt,
                        // Сессию сообщает только сервер, поэтому её число
                        // точное даже тогда, когда неделя посчитана на месте.
                        isEstimate: false,
                        startedAt: session.startedAt
                        // Модель за эти пять часов ядру взять неоткуда: она
                        // считается по транскриптам, а сюда приходит уже
                        // готовый снимок. Досчитывает её слой приложения —
                        // `LimitAlert.with(topModel:)` перед самой отправкой.
                    )
                )
            }
        }

        guard !due.isEmpty else { return [] }

        // Остывание. Сказанное не теряется: лог не тронут, и на следующем
        // обновлении тот же порог придёт снова — уже отлежавшись.
        // Часы, переведённые назад, остыванием не считаются: иначе один
        // перевод стрелок запирал бы уведомления до конца суток.
        if let last = log.lastSentAt {
            let since = now.timeIntervalSince(last)
            if since >= 0 && since < cooldown { return [] }
        }

        for alert in due {
            switch alert.kind {
            case .week: log.weekSaid = alert.threshold
            case .session: log.sessionSaid = alert.threshold
            }
        }
        log.lastSentAt = now
        return due
    }
}
